import Foundation

/// CPU und Speicher eines Prozesses laut `/bin/ps`. `ps` ist setuid-root und liest damit auch Prozesse anderer
/// Benutzer, für die `proc_pid_rusage` ohne Root `EPERM` liefert. Die Werte sind anders gemessen als bei eigenen
/// Prozessen: CPU als von `ps` geglätteter Anteil, Speicher als Resident Set Size statt `ri_phys_footprint`.
public struct ForeignProcessUsage: Hashable, Sendable {
    public let uid: UInt32
    /// Anteil an allen Kernen (0…1, wie `ProcessMeasurement.cpuLoad`).
    public let cpuLoad: Double
    public let residentBytes: UInt64

    public init(uid: UInt32, cpuLoad: Double, residentBytes: UInt64) {
        self.uid = uid
        self.cpuLoad = cpuLoad
        self.residentBytes = residentBytes
    }
}

/// Liest die Ausgabe von `ps -axo pid=,uid=,pcpu=,rss=`. Bewusst ohne `comm`/`args`: Namen kommen aus
/// `sysctl(KERN_PROC_ALL)`, Befehlszeilen gelangen nie in Grantry.
public enum PSUsageParser {
    public static let arguments = ["-axo", "pid=,uid=,pcpu=,rss="]

    /// Je PID; `pcpu` (100 = ein Kern) wird auf alle Kerne bezogen, `rss` (KiB) in Byte umgerechnet. Komma und Punkt
    /// gelten als Dezimaltrenner (`ps` folgt `LC_NUMERIC`); unlesbare Zeilen entfallen.
    public static func parse(_ output: String, coreCount: Int) -> [Int32: ForeignProcessUsage] {
        var usage: [Int32: ForeignProcessUsage] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, let pid = Int32(fields[0]), pid >= 0, let uid = UInt32(fields[1]),
                  let percent = Double(fields[2].replacingOccurrences(of: ",", with: ".")), percent.isFinite,
                  percent >= 0, let kibibytes = UInt64(fields[3]) else { continue }
            let (bytes, overflow) = kibibytes.multipliedReportingOverflow(by: 1024)
            usage[pid] = ForeignProcessUsage(uid: uid, cpuLoad: min(1, percent / 100 / Double(max(coreCount, 1))),
                                             residentBytes: overflow ? .max : bytes)
        }
        return usage
    }
}

extension TaskManagerSnapshot {
    /// Ergänzt CPU und Speicher von Prozessen anderer Benutzer aus `ps`, wo `proc_pid_rusage` nichts lieferte – nur bei
    /// gleicher PID **und** gleichem Benutzer. `ps` kennt keine Startzeit; eine im selben Moment neu vergebene PID desselben
    /// Benutzers kann für einen Takt die Werte ihres Vorgängers zeigen (nur Anzeige). Datenträger bleibt leer.
    public func fillingForeignUsage(_ usage: [Int32: ForeignProcessUsage], currentUID: UInt32) -> TaskManagerSnapshot {
        guard !usage.isEmpty else { return self }
        var filled = self
        filled.processes = processes.map { process in
            guard process.uid != currentUID, process.cpuLoad == nil, process.memoryBytes == nil,
                  let foreign = usage[process.key.pid], foreign.uid == process.uid else { return process }
            return ProcessMeasurement(
                key: process.key, parentPID: process.parentPID, uid: process.uid, name: process.name,
                cpuLoad: foreign.cpuLoad, memoryBytes: foreign.residentBytes, diskReadPerSecond: nil,
                diskWritePerSecond: nil, threadCount: process.threadCount, executablePath: process.executablePath,
                cpuTimeNanoseconds: process.cpuTimeNanoseconds
            )
        }
        return filled
    }
}
