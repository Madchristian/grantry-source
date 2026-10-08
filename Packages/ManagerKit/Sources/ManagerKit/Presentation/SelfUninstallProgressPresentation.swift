import Foundation

/// Anzeige von „Grantry deinstallieren …“ während und nach dem Ablauf (#143): je Schritt Titel, Zustand als Text und
/// Symbol (nicht nur Farbe), Hinweise zum laufenden Schritt, danach Bericht, nächste Schritte und ob eine Wiederholung
/// möglich ist. Bietet bewusst keinen Abbruch an – an Finder oder `SMAppService` gesendete Aufträge laufen weiter.
public struct SelfUninstallProgressPresentation: Hashable, Sendable {
    public struct StepRow: Hashable, Sendable, Identifiable {
        public let step: SelfUninstallStep
        public let title: String
        public let state: SelfUninstallProgress.StepState
        public let statusText: String
        /// SF Symbol des Zustands; `nil` für den laufenden Schritt (Fortschrittsanzeige).
        public let systemImage: String?
        public let tone: PresentationTone

        public var id: SelfUninstallStep { step }
        /// „In den Papierkorb legen: Läuft …“ – für VoiceOver eine Zeile.
        public var accessibilityLabel: String { "\(title): \(statusText)" }
    }

    public let title: String
    public let rows: [StepRow]
    public let isRunning: Bool
    /// Was der laufende Schritt bedeutet (z. B. Passwortabfrage des Finders, mögliche Teilergebnisse).
    public let runningHint: String?
    /// Hinweise unter den Schritten – während des Ablaufs, dass sich nichts abbrechen lässt; danach zur Wiederholung.
    public let notes: [String]
    /// Bericht nach dem Ende mit den nächsten Schritten (`ActionOutcomePresentation.selfUninstall`).
    public let outcome: ActionOutcomePresentation?
    /// Ob „Erneut versuchen“ angeboten wird (noch offene Teile des bestätigten Plans).
    public let offersRetry: Bool
    /// Grantry liegt im Papierkorb – „Beenden“ statt „Schließen“.
    public let quitsApp: Bool
    /// Grantry liegt im Papierkorb, aber ein Dienst ist noch angemeldet: Verweis auf *Anmeldeobjekte & Erweiterungen*
    /// zum manuellen Entfernen (#143).
    public let offersLoginItemsSettings: Bool
    /// Statusmeldung für VoiceOver: der begonnene Schritt bzw. am Ende das Ergebnis.
    public let announcement: String?

    public init(_ progress: SelfUninstallProgress, home: String = NSHomeDirectory()) {
        let report = progress.report
        rows = progress.steps.map { step in Self.row(step, state: progress.state(of: step)) }
        isRunning = report == nil
        outcome = report.map { ActionOutcomePresentation.selfUninstall($0, home: home) }
        quitsApp = report?.appRemoved == true
        offersRetry = progress.retryPlan != nil
        offersLoginItemsSettings = quitsApp && report?.servicesStillRegistered.isEmpty == false
        if let report {
            title = report.isComplete ? SelfUninstallProgressTexts.finishedTitle : SelfUninstallProgressTexts.unfinishedTitle
            runningHint = nil
            notes = offersRetry ? [SelfUninstallProgressTexts.retryNote] : []
            announcement = outcome?.text
        } else {
            title = progress.attempt > 1
                ? SelfUninstallProgressTexts.retryingTitle(attempt: progress.attempt) : SelfUninstallProgressTexts.runningTitle
            runningHint = progress.runningStep.map(SelfUninstallProgressTexts.hint(for:))
            notes = [SelfUninstallProgressTexts.noCancelNote]
            announcement = progress.runningStep.map { "\(SelfUninstallProgressTexts.title(of: $0)): \(Self.statusText(.running))" }
        }
    }

    static func row(_ step: SelfUninstallStep, state: SelfUninstallProgress.StepState) -> StepRow {
        let (systemImage, tone): (String?, PresentationTone) = switch state {
        case .pending: ("circle", .neutral)
        case .running: (nil, .neutral)
        case .done: (PresentationTone.positive.systemImage, .positive)
        case .skipped: ("minus.circle", .neutral)
        case .partial: (PresentationTone.warning.systemImage, .warning)
        case .failed: (PresentationTone.critical.systemImage, .critical)
        case .blocked: ("slash.circle", .neutral)
        }
        return StepRow(
            step: step, title: SelfUninstallProgressTexts.title(of: step), state: state, statusText: statusText(state),
            systemImage: systemImage, tone: tone
        )
    }

    static func statusText(_ state: SelfUninstallProgress.StepState) -> String {
        switch state {
        case .pending: "Ausstehend"
        case .running: "Läuft …"
        case .done: "Erledigt"
        case .skipped: "Nichts zu tun"
        case .partial: "Teilweise erledigt"
        case .failed: "Fehlgeschlagen"
        case .blocked: "Nicht ausgeführt"
        }
    }
}

enum SelfUninstallProgressTexts {
    static let runningTitle = "Grantry wird deinstalliert …"
    static let finishedTitle = "Grantry deinstalliert"
    static let unfinishedTitle = "Deinstallation nicht abgeschlossen"
    static let noCancelNote = "Ein an macOS oder den Finder gesendeter Schritt lässt sich nicht abbrechen. Grantry wartet "
        + "sein Ergebnis ab – auch beim Beenden."
    static let retryNote = "„Erneut versuchen“ setzt nur die noch offenen Teile der bestätigten Auswahl fort; "
        + "Erledigtes wird nicht wiederholt."

    static func retryingTitle(attempt: Int) -> String { "Erneuter Versuch (\(attempt)) …" }

    static func title(of step: SelfUninstallStep) -> String {
        switch step {
        case .finderAccess: "Finder-Freigabe prüfen"
        case .services: "Hintergrunddienst und „Beim Anmelden starten“ abmelden"
        case .permissions: "Berechtigungen zurücksetzen"
        case .trash: "In den Papierkorb legen"
        case .finderAutomation: "Finder-Automation zurücksetzen"
        }
    }

    static func hint(for step: SelfUninstallStep) -> String {
        switch step {
        case .finderAccess:
            "Fragt macOS, ob Grantry den Finder steuern darf, bitte dort antworten."
        case .services:
            "macOS meldet die Dienste ab – das kann einen Moment dauern."
        case .permissions:
            "Die gewählten Berechtigungen werden zurückgesetzt."
        case .trash:
            "Der Finder legt die Auswahl in den Papierkorb. Fragt er nach dem Passwort, bitte dort bestätigen. Wird die "
                + "Abfrage abgebrochen, bleibt Grantry installiert; bereits Verschobenes liegt dann im Papierkorb."
        case .finderAutomation:
            "Die Finder-Freigabe von Grantry wird zurückgesetzt."
        }
    }
}
