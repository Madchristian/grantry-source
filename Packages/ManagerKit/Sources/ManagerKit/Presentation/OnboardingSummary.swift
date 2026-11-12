// Onboarding im Lagebild (LB-5.3, #554; Entwurf LB-5.1, Spec 2026-11-10 § 11.5 d und Korrektur): Kopf mit Schild und
// Urteil über die Einrichtung, dazu die zwei Schritte nur im Onboarding – Updates (Zustimmung) und erster Scan als
// Ausgangsbasis. Die Prüfzeilen der vier Einrichtungsschritte kommen unverändert aus `SetupChecklist`.

/// Zusammenfassung des Onboardings: Urteil, Fortschritt, Schildform und Zustände der Zusatzzeilen.
public struct OnboardingSummary: Hashable, Sendable {
    /// Stand des ersten Scans.
    public enum Baseline: Hashable, Sendable {
        /// Folgt nach „Fertig“.
        case pending
        /// Ein Scan läuft.
        case scanning
        /// Ausgangsbasis gespeichert.
        case saved
    }

    /// Ton eines Zustands; die App bildet ihn auf die Töne der Instrumententafel ab.
    public enum Tone: Hashable, Sendable {
        case neutral, running, positive, finding
    }

    /// Zustand als kurzer Text mit Ton (Zustandschip).
    public struct Status: Hashable, Sendable {
        public let text: String
        public let tone: Tone

        public init(text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    /// Schildform des Kopfs: offen bis zur gespeicherten Ausgangsbasis (kein Urteil, keine Entwarnung), danach mit
    /// Urteil.
    public enum Shield: Hashable, Sendable {
        case open
        case judged(finding: Bool)
    }

    public let checklist: SetupChecklist
    public let checksUpdatesDaily: Bool
    public let baseline: Baseline

    public init(checklist: SetupChecklist, checksUpdatesDaily: Bool, baseline: Baseline) {
        self.checklist = checklist
        self.checksUpdatesDaily = checksUpdatesDaily
        self.baseline = baseline
    }

    /// Schritte des Onboardings: die Einrichtung, Updates und der erste Scan.
    public var stepCount: Int { checklist.items.count + 2 }

    /// Erledigte Schritte. Über Updates ist mit dem Schalter immer entschieden, in beide Richtungen.
    public var doneCount: Int {
        checklist.items.count { $0.state == .done } + 1 + (baseline == .saved ? 1 : 0)
    }

    /// Detailzeile des Panels „Einrichtung“: „4 von 6 erledigt“.
    public var progressText: String { "\(doneCount) von \(stepCount) erledigt" }

    /// Kenndaten rechts im Kopf: „6 Schritte“.
    public var stepsText: String { "\(stepCount) Schritte" }

    /// Urteil als Chip: offene Schritte vor laufendem Scan; „bereit“ erst, wenn alles geprüft ist.
    public var verdict: Status {
        let open = checklist.items.count { $0.state == .open || $0.state == .blocked }
        if open > 0 { return Status(text: "\(open) offen", tone: .finding) }
        if baseline == .scanning { return Status(text: "Scan läuft", tone: .running) }
        if checklist.items.contains(where: { $0.state == .checking }) { return Status(text: "wird geprüft", tone: .neutral) }
        return Status(text: "bereit", tone: .positive)
    }

    public var shield: Shield {
        baseline == .saved ? .judged(finding: verdict.tone == .finding) : .open
    }

    /// Grund der Zeile „Updates“ in einem Satz: der erste Satz des Datenschutzhinweises.
    public static var updatesReason: String { UpdateFeed.privacyNote.splitFirstSentence().first }

    /// Rest des Datenschutzhinweises für die aufgeklappte Zeile „Updates“.
    public static var updatesExplanation: String? { UpdateFeed.privacyNote.splitFirstSentence().rest }

    /// Zustand der Zeile „Updates“.
    public var updatesStatus: Status {
        checksUpdatesDaily ? Status(text: "Täglich prüfen", tone: .positive) : Status(text: "Nicht prüfen", tone: .neutral)
    }

    /// Zustand der Zeile „Erster Scan“.
    public var baselineStatus: Status {
        switch baseline {
        case .pending: Status(text: "Folgt nach „Fertig“", tone: .neutral)
        case .scanning: Status(text: "läuft", tone: .running)
        case .saved: Status(text: "Ausgangsbasis gespeichert", tone: .positive)
        }
    }
}
