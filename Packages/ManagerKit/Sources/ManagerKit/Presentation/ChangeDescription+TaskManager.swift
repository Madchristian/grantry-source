// MARK: - Task-Manager (TM-9.5)

extension ChangeDescription {
    /// „Prozess beendet“ – „„agent“ (PID 4242, Benutzer root).“ bzw. mit Grund bei Fehlschlag. Dienste (TM10) nennen
    /// statt der PID nur das Label: „„com.example.agent“ (Benutzer mara).“
    static func describe(_ record: TaskActionRecord) -> Self {
        let pid = record.pid.map { "PID \($0), " } ?? ""
        let subject = "„\(record.processName)“ (\(pid)Benutzer \(record.userName))"
        let action: String = switch record.action {
        case .terminate: "Prozess beendet"
        case .forceTerminate: "Prozess sofort beendet"
        case .setPriority: "Priorität geändert"
        case .startService: "Dienst gestartet"
        case .stopService: "Dienst gestoppt"
        }
        let detail: String = if case .setPriority(let priority) = record.action { " auf „\(priority.title)“" } else { "" }
        switch record.outcome {
        case .done:
            return Self(title: action, body: "\(subject)\(detail).")
        case .failed(let message):
            return Self(title: "\(action) – gescheitert", body: "\(subject)\(detail): \(message)")
        }
    }
}
