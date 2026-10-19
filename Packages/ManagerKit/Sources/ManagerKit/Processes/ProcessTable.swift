import Darwin
import Foundation
import GrantryShared

/// Ein Eintrag der Prozesstabelle für das Segment „Prozesse“ (#221). Programmpfad, Argumente, Arbeitsordner und
/// Speicher liest Grantry nur für Prozesse des eigenen Benutzers; bei fremden bleiben sie leer.
///
/// Argumente dienen nur dem Abgleich mit dem `AgentProcessCatalog` und verlassen den Speicher nie: Angezeigt und
/// protokolliert wird `label` (Programmname, ggf. Skriptname) – nie die Befehlszeile, die Geheimnisse tragen kann.
public struct ProcessEntry: Hashable, Sendable {
    public let pid: pid_t
    public let parentPID: pid_t
    public let uid: UInt32
    /// Mikrosekunden seit 1970 wie `RunningProcess.startTime`.
    public let startTime: UInt64
    /// `""`, wenn nicht lesbar.
    public let executablePath: String
    let arguments: [String]
    /// Arbeitsordner; `nil`, wenn nicht lesbar.
    let workingDirectory: String?
    /// Physischer Speicher (`ri_phys_footprint`, wie „Speicher“ in der Aktivitätsanzeige); `nil`, wenn nicht lesbar.
    public let memoryBytes: UInt64?
    /// Leitet der Prozess seine eigene Sitzung (`getsid(pid) == pid`)? launchd startet Dienste so (`setsid`); das
    /// Kind einer beendeten Agenten-Sitzung behält dagegen deren Sitzung. `nil`, wenn nicht lesbar.
    let isSessionLeader: Bool?

    init(pid: pid_t, parentPID: pid_t, uid: UInt32, startTime: UInt64, executablePath: String = "",
         arguments: [String] = [], workingDirectory: String? = nil, memoryBytes: UInt64? = nil,
         isSessionLeader: Bool? = nil) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.startTime = startTime
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.memoryBytes = memoryBytes
        self.isSessionLeader = isSessionLeader
    }

    /// Identität für Signale (`ProcessTerminationPolicy` prüft Pfad, Benutzer und Startzeit unmittelbar vorher).
    public var runningProcess: RunningProcess {
        RunningProcess(pid: pid, uid: uid, executablePath: executablePath, startTime: startTime)
    }

    /// Lesbarer Name ohne Argumente: Programmname, bei Interpretern mit dem Skriptnamen („node app-server-broker.mjs“).
    public var label: String {
        let program = Self.lastComponent(executablePath.isEmpty ? (arguments.first ?? "") : executablePath)
        guard arguments.count > 1, arguments[1].hasPrefix("/") else { return DisplayText.singleLine(program) }
        return DisplayText.singleLine(program + " " + Self.lastComponent(arguments[1]))
    }

    static func lastComponent(_ path: String) -> String { (path as NSString).lastPathComponent }
}

/// Liest die Prozesstabelle.
public protocol ProcessTableReading: Sendable {
    func entries() throws -> [ProcessEntry]
}

public struct ProcessTableError: LocalizedError, Equatable {
    let code: Int32

    public var errorDescription: String? { "Prozessliste nicht lesbar (errno \(code))" }
}

/// `ProcessTableReading` über `sysctl(KERN_PROC_ALL)` (PID, Eltern, Benutzer, Startzeit aller Prozesse in einem Aufruf)
/// und libproc/`KERN_PROCARGS2` für die Details eigener Prozesse.
public struct LibprocProcessTable: ProcessTableReading {
    private let currentUID: UInt32

    public init(currentUID: UInt32 = getuid()) {
        self.currentUID = currentUID
    }

    public func entries() throws -> [ProcessEntry] {
        try Self.kernelEntries().compactMap { info in
            let pid = info.kp_proc.p_pid
            guard pid > 0, Int32(info.kp_proc.p_stat) != SZOMB,
                  let startTime = LibprocProcessInspector.microseconds(info.kp_proc.p_un.__p_starttime) else { return nil }
            let uid = info.kp_eproc.e_ucred.cr_uid
            let parent = info.kp_eproc.e_ppid
            guard uid == currentUID else { return ProcessEntry(pid: pid, parentPID: parent, uid: uid, startTime: startTime) }
            return ProcessEntry(
                pid: pid, parentPID: parent, uid: uid, startTime: startTime,
                executablePath: LibprocProcessInspector.executablePath(of: pid) ?? "",
                arguments: Self.arguments(of: pid), workingDirectory: Self.workingDirectory(of: pid),
                memoryBytes: Self.footprint(of: pid), isSessionLeader: Self.isSessionLeader(pid)
            )
        }
    }

    static func kernelEntries() throws -> [kinfo_proc] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0 else { throw ProcessTableError(code: errno) }
        // Reserve: zwischen den Aufrufen können Prozesse hinzukommen.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&name, u_int(name.count), &buffer, &size, nil, 0) == 0 else { throw ProcessTableError(code: errno) }
        return Array(buffer.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    /// argv laut `KERN_PROCARGS2`: `argc` (Int32), Programmpfad, Füll-Nullbytes, dann `argc` Zeichenketten.
    static func arguments(of pid: pid_t) -> [String] {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, u_int(name.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return parseArguments(Array(buffer.prefix(size)))
    }

    static func parseArguments(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > MemoryLayout<Int32>.size else { return [] }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Programmpfad überspringen, dann die Füll-Nullbytes.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return string(from: info.pvi_cdir.vip_path)
    }

    /// Nullterminierter C-Puffer fester Länge (`vip_path`, `p_comm`) als Text; `nil`, wenn leer.
    static func string<Buffer>(from buffer: Buffer) -> String? {
        let text = withUnsafeBytes(of: buffer) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return text.isEmpty ? nil : text
    }

    private static func isSessionLeader(_ pid: pid_t) -> Bool? {
        let session = getsid(pid)
        return session < 0 ? nil : session == pid
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }
}
