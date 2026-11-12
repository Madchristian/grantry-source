// Einrichtung als Prüfzeilen in den Einstellungen (LB-5.2, #553; Spec 2026-11-10 § 11.5 c und e, Standard § 3.10a):
// Grund in einem Satz, kurzer Zustand für den Chip, Kopf des Panels und die beim Öffnen aufgeklappte Zeile. Die Texte
// stammen unverändert aus `SetupStep` und `SetupChecklist`; hier werden sie nur aufgeteilt.

extension SetupStep {
    /// Grund in einem Satz für die Prüfzeile: der erste Satz der Erklärung.
    public var reason: String {
        explanation.splitFirstSentence().first
    }

    /// Rest der Erklärung für die aufgeklappte Prüfzeile; `nil`, wenn die Erklärung nur einen Satz hat.
    public var furtherExplanation: String? {
        explanation.splitFirstSentence().rest
    }
}

extension String {
    /// Erster Satz und Rest (`nil`, wenn der Text nur einen Satz hat) – für den Grund einer Prüfzeile.
    func splitFirstSentence() -> (first: String, rest: String?) {
        guard let end = range(of: ". ") else { return (self, nil) }
        return (String(self[..<index(after: end.lowerBound)]), String(self[end.upperBound...]))
    }
}

extension SetupChecklist.Item {
    /// Zustand für den Zustandschip: kurz, wenn der volle Text dafür zu lang ist.
    public var chipText: String { shortText ?? text }

    /// Voller Zustand für die aufgeklappte Prüfzeile, wenn der Chip ihn verkürzt; sonst `nil`.
    public var detailText: String? { chipText == text ? nil : text }

    var isOpen: Bool { state == .open || state == .blocked }
}

extension SetupChecklist {
    /// Zeile, die beim Öffnen aufgeklappt ist (wie in Sicherheit): der erste fehlende erforderliche Schritt, sonst der
    /// erste offene; `nil`, solange nichts offen ist.
    public var leadingStep: SetupStep? {
        missingRequired.first?.step ?? nextStep
    }

    /// Ob ein Schritt offen ist (auch ein nicht behebbarer); ungeprüfte zählen nicht.
    public var hasOpenSteps: Bool { items.contains(where: \.isOpen) }

    /// Detailzeile im Kopf des Panels „Einrichtung“: „3 von 4 erledigt · 1 kritisch“.
    public var panelDetail: String {
        guard items.contains(where: { $0.state != .checking }) else { return "Zustand wird gelesen …" }
        let done = items.count { $0.state == .done }
        let critical = items.count { $0.tone == .critical }
        let summary = "\(done) von \(items.count) erledigt"
        return critical > 0 ? "\(summary) · \(critical) kritisch" : summary
    }

    /// Wert im Kopf des Panels: „2 offen“, leer ohne offene Schritte.
    public var panelValue: String {
        let open = items.count(where: \.isOpen)
        return open > 0 ? "\(open) offen" : ""
    }
}
