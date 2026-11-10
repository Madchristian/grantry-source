import os

/// Meldet jeden Messtakt als Debug-Eintrag im Unified Log (Kategorie `sampling`). Ohne Mitleser verwirft das System
/// Debug-Einträge sofort; die Leistungsabnahme schneidet sie per `log stream --level debug` mit und belegt so
/// unabhängig von der CPU-Zeit, dass die Messung nach dem Ausblenden endet (`scripts/performance/task_manager_budget.py`).
enum SamplingTrace {
    enum Source: String {
        case taskManager = "task-manager"
        case sensors
        /// Eigener Takt des Wachbuchs (TM-12.3), ohne Task-Manager.
        case watchbook
    }

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "sampling")

    static func tick(_ source: Source) {
        logger.debug("Takt \(source.rawValue, privacy: .public)")
    }
}
