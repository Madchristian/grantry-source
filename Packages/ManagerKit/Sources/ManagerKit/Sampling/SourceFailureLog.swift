import os
import Synchronization

/// Meldet jede ausgefallene Quelle einmal je Lebensdauer (Spec §5: einmal pro Sitzung, nicht pro Takt). Das Model hält
/// eine Instanz über alle Läufe, damit ein Taktwechsel nicht erneut meldet.
public final class SourceFailureLog: Sendable {
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "task-manager")

    private let reported = Mutex<Set<TaskManagerSource>>([])
    private let report: @Sendable (TaskManagerSource, any Error) -> Void

    public init(report: @escaping @Sendable (TaskManagerSource, any Error) -> Void = SourceFailureLog.log) {
        self.report = report
    }

    func note(_ readings: TaskManagerReadings) {
        for (source, error) in readings.failures where reported.withLock({ $0.insert(source).inserted }) {
            report(source, error)
        }
    }

    public static func log(_ source: TaskManagerSource, _ error: any Error) {
        logger.error(
            "Quelle \(source.rawValue, privacy: .public) nicht lesbar: \(String(describing: error), privacy: .public)"
        )
    }
}
