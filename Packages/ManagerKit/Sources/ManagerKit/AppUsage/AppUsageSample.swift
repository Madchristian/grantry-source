import Foundation
import GrantryShared

/// Ein gemessener Abschnitt (ein Takt) für den App-Verlauf.
public struct AppUsageSample: Sendable {
    public let end: Date
    public let seconds: Double
    /// Ob nettop in diesem Takt Netzraten lieferte.
    public let measuresNetwork: Bool
    public let usage: [(AppUsageSubject, AppUsageTotals)]

    public init(end: Date, seconds: Double, measuresNetwork: Bool, usage: [(AppUsageSubject, AppUsageTotals)]) {
        self.end = end
        self.seconds = seconds
        self.measuresNetwork = measuresNetwork
        self.usage = usage
    }

    /// Aus einem Takt des Task-Managers: nur eigene Prozesse (Gruppen „Apps“ und „Hintergrund“ des `ProcessGrouper`),
    /// je Eintrag Rate × verstrichene Zeit; Einträge ohne Verbrauch entfallen. Nicht gemessene Energie und Netzrate
    /// bleiben `nil`. `nil` beim ersten Takt (keine Zeit)
    /// und ohne Prozessmessung (etwa wenn nur die Menüleiste misst).
    public static func make(frame: TaskManagerFrame, apps: [RunningApp], currentUID: UInt32,
                            network: [ProcessKey: Double]?, at end: Date,
                            fallbackCoreCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> AppUsageSample? {
        guard let elapsed = frame.elapsed, elapsed > .zero, !frame.snapshot.processes.isEmpty else { return nil }
        let seconds = elapsed.seconds
        let cores = frame.snapshot.cpu.map(\.cores.count).flatMap { $0 > 0 ? $0 : nil } ?? fallbackCoreCount
        // Nur Prozesse mit Verbrauch bilden Einträge; untätige trügen nichts bei (#489).
        let entries = ProcessGrouper.ownEntries(frame.snapshot.processes, apps: apps, currentUID: currentUID,
                                                network: network) { process in
            Self.isActive(process, network: network)
        }
        var order: [AppUsageSubject] = []
        var totals: [AppUsageSubject: AppUsageTotals] = [:]
        for entry in entries where !entry.name.isEmpty {
            let figures = entry.totals
            let used = AppUsageTotals(
                cpuSeconds: (figures.cpuLoad ?? 0) * Double(cores) * seconds,
                energyJoules: figures.energyMilliwatts.map { $0 / 1_000 * seconds },
                networkBytes: figures.networkPerSecond.map { $0 * seconds },
                diskBytes: (figures.diskPerSecond ?? 0) * seconds
            )
            guard !used.isUnused else { continue }
            let subject = entry.app.map {
                AppUsageSubject(kind: .app, bundleID: $0.bundleID, name: $0.name, bundlePath: $0.bundlePath)
            } ?? AppUsageSubject(kind: .process, bundleID: nil, name: entry.name, bundlePath: nil)
            if totals[subject] == nil { order.append(subject) }
            totals[subject, default: .empty] += used
        }
        return AppUsageSample(end: end, seconds: seconds, measuresNetwork: network != nil,
                              usage: order.map { ($0, totals[$0] ?? .empty) })
    }

    /// Hat in diesem Takt CPU, Datenträger, Energie oder Netz verbraucht.
    private static func isActive(_ process: ProcessMeasurement, network: [ProcessKey: Double]?) -> Bool {
        (process.cpuLoad ?? 0) > 0 || (process.diskReadPerSecond ?? 0) > 0 || (process.diskWritePerSecond ?? 0) > 0
            || (process.energyMilliwatts ?? 0) != 0 || (network?[process.key] ?? 0) > 0
    }
}
