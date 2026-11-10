import Darwin
import GrantryShared
import Synchronization

/// Verbrauchszähler eines eigenen Prozesses (`proc_pid_rusage`, `PROC_PIDTASKINFO`); `nil`, was nicht gelesen wurde.
struct ResourceUsage: Hashable, Sendable {
    let cpuTimeNanoseconds: UInt64
    let diskBytesRead: UInt64?
    let diskBytesWritten: UInt64?
    let memoryBytes: UInt64
    let threadCount: Int?
    /// `ri_energy_nj`; nur auf Apple Silicon.
    var energyNanojoules: UInt64? = nil
}

/// Messquelle „Prozesse“ des Task-Managers (Spec 2026-11-06 §3, §5): alle Prozesse aus einem `sysctl(KERN_PROC_ALL)`
/// (`LibprocProcessTable.kernelProcesses()`), für eigene dazu CPU-Zeit, Datenträger-Bytes und Speicher
/// (`proc_pid_rusage`, `RUSAGE_INFO_V6`), Threads (`PROC_PIDTASKINFO`) und der Programmpfad (`proc_pidpath`, für Name
/// und App-Zuordnung). Für Prozesse anderer Benutzer liefert macOS diese Zähler ohne Root nicht (`EPERM`, am
/// 2026-11-06 geprüft): Sie erscheinen mit dem Kurznamen des Kernels, ohne Pfad und ohne Zähler – die Oberfläche zeigt
/// „–“, nie 0. Argumente und Befehlszeilen liest der Sampler nie.
///
/// Energie (`ri_energy_nj`, TM8) füllt macOS nur auf Apple Silicon; auf Intel bleibt sie `nil` statt 0.
///
/// `ri_user_time`/`ri_system_time` zählen in Mach-Ticks (Apple Silicon: 125/3 ns je Tick), `nanoseconds` rechnet mit
/// `mach_timebase_info` um. Pfad und Name eines eigenen Prozesses merkt sich `ProcessProgramCache` je Prozessgeneration.
public struct ProcessUsageSampler: MetricSource {
    private let currentUID: UInt32
    private let processes: @Sendable () throws -> [KernelProcess]
    private let usage: @Sendable (pid_t) -> ResourceUsage?
    private let executablePath: @Sendable (pid_t) -> String?
    private let programs = ProcessProgramCache()

    public init(currentUID: UInt32 = getuid()) {
        let timebase = Self.timebase()
        self.init(currentUID: currentUID, processes: LibprocProcessTable.kernelProcesses,
                  usage: { Self.usage(of: $0, numer: timebase.numer, denom: timebase.denom) },
                  executablePath: LibprocProcessInspector.executablePath(of:))
    }

    /// Nur CPU-Zeit und Speicher eigener Prozesse (`KERN_PROC_UID`, `RUSAGE_INFO_V0`) – für den Wachbuch-Takt
    /// (TM-12.3), der je Punkt nur die größten Verbraucher nach CPU und Speicher führt. Fremde Prozesse liefern ohne
    /// Root ohnehin keine Zähler; Threads (`PROC_PIDTASKINFO`), Datenträger und Energie (`RUSAGE_INFO_V6`) führt das
    /// Wachbuch nicht. Im Hintergrund läuft der Takt gedrosselt, dort kostete der volle Sampler rund 11 statt 4 ms (#530).
    public static func ownLoad(currentUID: UInt32 = getuid()) -> ProcessUsageSampler {
        let timebase = Self.timebase()
        return ProcessUsageSampler(currentUID: currentUID,
                                   processes: { try LibprocProcessTable.kernelProcesses(ownedBy: currentUID) },
                                   usage: { Self.load(of: $0, numer: timebase.numer, denom: timebase.denom) },
                                   executablePath: LibprocProcessInspector.executablePath(of:))
    }

    init(currentUID: UInt32, processes: @escaping @Sendable () throws -> [KernelProcess],
         usage: @escaping @Sendable (pid_t) -> ResourceUsage?, executablePath: @escaping @Sendable (pid_t) -> String?) {
        self.currentUID = currentUID
        self.processes = processes
        self.usage = usage
        self.executablePath = executablePath
    }

    public func read() throws -> [ProcessCounters] {
        let listed = try processes()
        let known = programs.resolve(listed.filter { $0.uid == currentUID }, path: executablePath)
        return listed.map { process in
            let isOwn = process.uid == currentUID
            let usage = isOwn ? usage(process.pid) : nil
            let program = isOwn ? known[ProcessKey(pid: process.pid, startTime: process.startTime)] : nil
            return ProcessCounters(
                key: ProcessKey(pid: process.pid, startTime: process.startTime), parentPID: process.parentPID,
                uid: process.uid, name: program?.name ?? Self.name(command: process.command, executablePath: nil),
                cpuTimeNanoseconds: usage?.cpuTimeNanoseconds, diskBytesRead: usage?.diskBytesRead,
                diskBytesWritten: usage?.diskBytesWritten, memoryBytes: usage?.memoryBytes,
                threadCount: usage?.threadCount, executablePath: program?.path, energyNanojoules: usage?.energyNanojoules
            )
        }
    }

    /// Programmname ohne Argumente: letzter Pfadbestandteil, sonst der Kurzname des Kernels; einzeilig.
    static func name(command: String, executablePath: String?) -> String {
        let program = executablePath.map(ProcessEntry.lastComponent) ?? ""
        return DisplayText.singleLine(program.isEmpty ? command : program)
    }

    /// `nil`, wenn `proc_pid_rusage` scheitert (Prozess beendet oder fremd).
    static func usage(of pid: pid_t, numer: UInt32, denom: UInt32) -> ResourceUsage? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard result == 0 else { return nil }
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size ? Int(task.pti_threadnum) : nil
        return ResourceUsage(
            cpuTimeNanoseconds: nanoseconds(ticks: info.ri_user_time &+ info.ri_system_time, numer: numer, denom: denom),
            diskBytesRead: info.ri_diskio_bytesread, diskBytesWritten: info.ri_diskio_byteswritten,
            memoryBytes: info.ri_phys_footprint, threadCount: threads, energyNanojoules: energy(info.ri_energy_nj)
        )
    }

    /// CPU-Zeit und Speicher (`RUSAGE_INFO_V0`); `nil`, wenn `proc_pid_rusage` scheitert.
    static func load(of pid: pid_t, numer: UInt32, denom: UInt32) -> ResourceUsage? {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        guard result == 0 else { return nil }
        return ResourceUsage(
            cpuTimeNanoseconds: nanoseconds(ticks: info.ri_user_time &+ info.ri_system_time, numer: numer, denom: denom),
            diskBytesRead: nil, diskBytesWritten: nil, memoryBytes: info.ri_phys_footprint, threadCount: nil
        )
    }

    /// Energiezähler nur dort, wo macOS ihn füllt (Apple Silicon); auf Intel stünde dauerhaft 0.
    static func energy(_ nanojoules: UInt64) -> UInt64? {
        #if arch(arm64)
        nanojoules
        #else
        nil
        #endif
    }

    /// Mach-Ticks in Nanosekunden (`ticks · numer / denom`, ohne Überlauf im Zwischenergebnis).
    static func nanoseconds(ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom > 0 else { return ticks }
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        guard product.high < UInt64(denom) else { return .max }
        return UInt64(denom).dividingFullWidth(product).quotient
    }

    private static func timebase() -> (numer: UInt32, denom: UInt32) {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }
}

/// Pfad und Anzeigename eigener Prozesse je Prozessgeneration (PID + Startzeit) und Kurzname des Kernels: `proc_pidpath`
/// kostet bei 1 000 eigenen Prozessen rund 1 ms je Takt, ändert sich aber erst mit `exec` – und dann wechselt auch der
/// Kurzname, der deshalb mit dem Eintrag verglichen wird. Gesucht wird nach der Prozessgeneration (zwei Zahlen statt einer
/// Zeichenkette je Prozess; gedrosselt im Hintergrund zählt jeder Hash, #530). Jeder Takt behält nur die gerade gelisteten
/// Prozesse.
final class ProcessProgramCache: Sendable {
    struct Program: Sendable {
        let path: String?
        let name: String
        /// Kurzname des Kernels, unter dem der Pfad gelesen wurde.
        let command: String
    }

    private let programs = Mutex<[ProcessKey: Program]>([:])

    func resolve(_ own: [KernelProcess], path: (pid_t) -> String?) -> [ProcessKey: Program] {
        programs.withLock { cached in
            var current: [ProcessKey: Program] = [:]
            current.reserveCapacity(own.count)
            for process in own {
                let key = ProcessKey(pid: process.pid, startTime: process.startTime)
                if let program = cached[key], program.command == process.command {
                    current[key] = program
                } else {
                    let resolved = path(process.pid)
                    current[key] = Program(path: resolved, name: ProcessUsageSampler.name(command: process.command,
                                                                                          executablePath: resolved),
                                           command: process.command)
                }
            }
            cached = current
            return current
        }
    }
}
