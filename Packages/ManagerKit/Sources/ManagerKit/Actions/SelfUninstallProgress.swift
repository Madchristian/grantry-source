import Foundation

/// Sichtbarer Schritt von „Grantry deinstallieren …“ (#143). Fasst die Stufen des `SelfUninstaller` so zusammen, wie
/// der Nutzer sie erlebt: Helper und Login-Item sind ein Schritt „Dienste abmelden“.
public enum SelfUninstallStep: Hashable, Sendable, CaseIterable {
    /// Automation-Freigabe für den Finder prüfen (macOS fragt ggf. nach).
    case finderAccess
    /// Hintergrunddienst und „Beim Anmelden starten“ abmelden.
    case services
    /// Berechtigungen außer der Finder-Automation zurücksetzen.
    case permissions
    /// Auswahl in den Papierkorb legen (ggf. mit Passwortabfrage des Finders).
    case trash
    /// Zuletzt die Finder-Automation zurücksetzen.
    case finderAutomation

    /// Zu welchem Schritt ein Gegenstand des Berichts gehört.
    static func of(_ subject: SelfUninstallReport.Subject) -> SelfUninstallStep {
        switch subject {
        case .helper, .loginItem: .services
        case .grant(let grant): grant.service == PermissionCatalog.automationServiceID ? .finderAutomation : .permissions
        case .file: .trash
        }
    }

    /// Die Schritte eines Plans in Ablaufreihenfolge; Dienste meldet jeder Ablauf ab (bzw. prüft sie).
    static func steps(of plan: SelfUninstallPlan) -> [SelfUninstallStep] {
        let grantSteps = Set(plan.grants.map { of(.grant($0)) })
        return allCases.filter { step in
            switch step {
            case .finderAccess: !plan.files.isEmpty && plan.trashesFiles
            case .trash: !plan.files.isEmpty
            case .services: true
            case .permissions, .finderAutomation: grantSteps.contains(step)
            }
        }
    }
}

/// Meldung des `SelfUninstaller` während des Ablaufs (#143); die Oberfläche führt damit `SelfUninstallProgress` nach.
public enum SelfUninstallEvent: Hashable, Sendable {
    /// Ein Schritt beginnt – ab hier ist sein Auftrag an macOS, Finder bzw. Helper unterwegs.
    case started(SelfUninstallStep)
    /// Ein Schritt (bzw. eine seiner Stufen) ist fertig oder wurde wegen eines früheren Fehlers ausgelassen.
    case finished(SelfUninstallStep, [SelfUninstallReport.Entry])
}

/// Empfängt die Meldungen des Ablaufs; wird je Meldung abgewartet, damit die Reihenfolge erhalten bleibt.
public typealias SelfUninstallProgressHandler = @Sendable (SelfUninstallEvent) async -> Void

/// Fortschritt eines bestätigten Plans über alle Versuche (#143): welcher Schritt läuft, was erledigt, übersprungen,
/// gescheitert oder deswegen nicht ausgeführt ist, und – nach dem Ende – der zusammengeführte Bericht samt dem Plan einer
/// Wiederholung. Reine Logik; die Oberfläche zeigt sie über `SelfUninstallProgressPresentation`.
public struct SelfUninstallProgress: Hashable, Sendable {
    /// Zustand eines Schritts – in der Oberfläche mit eigenem Symbol und Text, nicht nur über die Farbe.
    public enum StepState: Hashable, Sendable {
        case pending, running, done
        /// Nichts zu tun (Dienst war nicht angemeldet).
        case skipped
        /// Teils erledigt, teils nicht (z. B. Passwortabfrage abgebrochen, ein Teil liegt schon im Papierkorb).
        case partial
        case failed
        /// Nicht ausgeführt, weil ein vorheriger Schritt oder die Finder-Freigabe fehlschlug.
        case blocked
    }

    /// Der vom Nutzer bestätigte Plan; jede Wiederholung bleibt eine Teilmenge davon.
    public let confirmedPlan: SelfUninstallPlan
    /// Schritte des bestätigten Plans in Ablaufreihenfolge.
    public let steps: [SelfUninstallStep]
    /// Nummer des laufenden bzw. letzten Versuchs (ab 1).
    public private(set) var attempt: Int
    /// Bericht über alle Versuche; `nil`, solange der Versuch läuft.
    public private(set) var report: SelfUninstallReport?
    private var running: SelfUninstallStep?
    /// Schritte, die dieser Versuch noch ausführt bzw. ausgeführt hat.
    private var scheduled: Set<SelfUninstallStep>
    private var finished: Set<SelfUninstallStep> = []
    /// Ergebnisse je Gegenstand über alle Versuche; dieser Versuch ersetzt nur, was er tatsächlich ausführt.
    private var entries: [SelfUninstallReport.Entry]
    /// Bericht der früheren Versuche, mit dem der des laufenden zusammengeführt wird.
    private let previous: SelfUninstallReport?

    /// Erster Versuch für den bestätigten Plan.
    public init(plan: SelfUninstallPlan) {
        self.init(confirmedPlan: plan, attemptPlan: plan, attempt: 1, previous: nil)
    }

    private init(
        confirmedPlan: SelfUninstallPlan, attemptPlan: SelfUninstallPlan, attempt: Int, previous: SelfUninstallReport?
    ) {
        self.confirmedPlan = confirmedPlan
        steps = SelfUninstallStep.steps(of: confirmedPlan)
        self.attempt = attempt
        self.previous = previous
        scheduled = Set(SelfUninstallStep.steps(of: attemptPlan))
        entries = previous?.entries ?? []
    }

    /// Ob der Versuch abgeschlossen ist.
    public var isFinished: Bool { report != nil }

    /// Der laufende Schritt; `nil` zwischen zwei Stufen und nach dem Ende.
    public var runningStep: SelfUninstallStep? { running }

    public mutating func apply(_ event: SelfUninstallEvent) {
        guard report == nil else { return }
        switch event {
        case .started(let step):
            running = step
        case .finished(let step, let results):
            entries = SelfUninstallReport.merge(entries, results)
            finished.insert(step)
            if running == step { running = nil }
        }
    }

    /// Schließt den Versuch mit dessen Bericht ab; der gespeicherte Bericht umfasst auch die früheren Versuche.
    public mutating func complete(with attemptReport: SelfUninstallReport) {
        let report = previous.map { attemptReport.carryingOver($0) } ?? attemptReport
        self.report = report
        entries = report.entries
        running = nil
        finished = Set(steps)
    }

    /// Zustand aus dem über alle Versuche zusammengeführten Stand – Erledigtes früherer Versuche bleibt erledigt, auch
    /// wenn der letzte an der Finder-Freigabe scheiterte.
    public func state(of step: SelfUninstallStep) -> StepState {
        if step == .finderAccess, report?.finderAccessFailure != nil { return .failed }
        if step == running { return .running }
        if scheduled.contains(step), !finished.contains(step) { return .pending }
        return Self.state(of: entries.filter { SelfUninstallStep.of($0.subject) == step }.map(\.result))
    }

    /// Ein übersprungener Gegenstand gilt als „nicht ausgeführt“ – außer ein Dienst, der nicht angemeldet war.
    static func state(of results: [RemovalReport.Result]) -> StepState {
        let isBlocked = { (result: RemovalReport.Result) in
            if case .skipped(let reason) = result { reason != SelfUninstaller.notRegisteredReason } else { false }
        }
        let done = results.filter(\.isDone).count
        let failed = results.filter { if case .failed = $0 { true } else { false } }.count
        if results.isEmpty || done == results.count { return .done }
        if failed > 0 { return done > 0 ? .partial : .failed }
        if results.allSatisfy(isBlocked) { return .blocked }
        if results.contains(where: isBlocked) { return done > 0 ? .partial : .blocked }
        return done > 0 ? .done : .skipped
    }

    /// Plan einer Wiederholung – nie mehr als der bestätigte Plan. Erledigte Berechtigungen fallen heraus; die Dienste
    /// prüft der `SelfUninstaller` ohnehin frisch (`SMAppService.status`). Dateien bleiben **alle** im Plan: Ihr Zustand
    /// stammt nie aus früheren Versuchen, der `SelfUninstaller` gleicht jede frisch ab (ein zurückgelegtes Original ist
    /// wieder offen). Liegt Grantry schon im Papierkorb, werden sie nur abgeglichen, nicht erneut an den Finder gegeben;
    /// eine Wiederholung gibt es dann nur für offene Dienste und Berechtigungen. `nil` vor dem Ende oder wenn der
    /// Bericht vollständig ist.
    public var retryPlan: SelfUninstallPlan? {
        guard let report, !report.isComplete else { return nil }
        let done = Set(report.entries.filter(\.result.isDone).map(\.subject))
        let grants = confirmedPlan.grants.filter { !done.contains(.grant($0)) }
        guard report.appRemoved else { return SelfUninstallPlan(files: confirmedPlan.files, grants: grants) }
        let hasOpen = !report.servicesStillRegistered.isEmpty || !grants.isEmpty
        return hasOpen ? SelfUninstallPlan(files: confirmedPlan.files, grants: grants, trashesFiles: false) : nil
    }

    /// Nächster Versuch mit `retryPlan`; `nil`, wenn keine Wiederholung möglich ist.
    public func retrying() -> (progress: SelfUninstallProgress, plan: SelfUninstallPlan)? {
        guard let report, let plan = retryPlan else { return nil }
        return (SelfUninstallProgress(confirmedPlan: confirmedPlan, attemptPlan: plan, attempt: attempt + 1, previous: report), plan)
    }
}

extension SelfUninstallReport {
    /// Ergebnisse je Gegenstand zusammengeführt: Das neuere gilt – außer es hat einen Dienst oder eine Berechtigung gar
    /// nicht ausgeführt (übersprungen: nicht angemeldet, nach einem Fehler ausgelassen, ohne Finder-Freigabe); dann
    /// bleibt ein früherer Erfolg stehen. Für Dateien gilt immer das neuere: Jeder Versuch gleicht sie frisch ab.
    /// Reihenfolge der älteren Liste.
    static func merge(_ older: [Entry], _ newer: [Entry]) -> [Entry] {
        let newerBySubject = Dictionary(newer.map { ($0.subject, $0) }, uniquingKeysWith: { _, last in last })
        let kept = older.map { old -> Entry in
            guard let new = newerBySubject[old.subject] else { return old }
            if case .file = old.subject { return new }
            if old.result.isDone, case .skipped = new.result { return old }
            return new
        }
        let known = Set(older.map(\.subject))
        return kept + newer.filter { !known.contains($0.subject) }
    }

    /// Dieser Bericht einer Wiederholung samt allen früheren Ergebnissen der Gegenstände, die sie nicht ausgeführt hat –
    /// Erfolge (etwa schon entsorgte Einstellungen für `clearsPreferences`) wie Offenes (etwa eine zurückgebliebene
    /// Datei, die eine reine Dienst-Wiederholung nicht anfasst).
    func carryingOver(_ previous: SelfUninstallReport) -> SelfUninstallReport {
        var merged = self
        merged.entries = Self.merge(previous.entries, entries)
        return merged
    }
}
