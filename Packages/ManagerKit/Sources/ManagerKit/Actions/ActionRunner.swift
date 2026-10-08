import Foundation
import Synchronization
import Observation

/// Ansicht, in der eine Aktion ausgelöst wurde; dort erscheint ihr Ergebnis. Je Bereich eine, damit die Meldung
/// sichtbar bleibt, wenn der betroffene Eintrag (oder seine Gruppe) nach der Aktion verschwindet.
public enum ActionContext: Hashable, Sendable {
    case permissions, autostart, security, history, apps, cleanup, agents, observations, network
}

/// Führt die verändernden Aktionen aus; in der App der `ActionCoordinator`.
public protocol ActionPerforming: Sendable {
    func reset(_ grant: PermissionGrant) async -> ActionOutcome
    func resetService(_ reset: ServiceReset) async -> ActionOutcome
    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async -> ActionOutcome
    func remove(_ item: AutostartItem) async -> ActionOutcome
    func restore(receiptID: UUID) async -> ActionOutcome
    /// MCP-Server entfernen, schalten, Änderung zurücknehmen (`ActionCoordinator+Agents.swift`).
    func removeServer(_ entry: MCPServerEntry) async -> ActionOutcome
    func setServerEnabled(_ entry: MCPServerEntry, _ enabled: Bool) async -> ActionOutcome
    func restoreAgentChange(_ change: AgentConfigChange) async -> ActionOutcome
    /// Beendet die Prozesse eines Lauschers (`ActionCoordinator+Processes.swift`).
    func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationResult
    func perform(_ action: SecurityAction) async -> ActionOutcome
    /// Entfernt App bzw. Reste (`ActionCoordinator.performRemoval(_:onExecuted:)`); `onExecuted` erhält den Bericht,
    /// sobald der Eingriff erledigt ist, noch vor dem Prüfscan. Ein Abbruch des aufrufenden Tasks startet keinen
    /// weiteren Schritt des Plans mehr (`ActionRunner.abandonRunningAction()`).
    func performRemoval(_ plan: RemovalPlan, onExecuted: @escaping @Sendable (RemovalReport) async -> Void) async -> RemovalReport
    /// Wartet, bis keine Aktion mehr läuft (vor dem Beenden).
    func drain() async
}

extension ActionCoordinator: ActionPerforming {}

/// Führt Aktionen über den `ActionCoordinator` aus und hält, was die Oberfläche dazu zeigt: welcher Eintrag gerade
/// bearbeitet wird und das Ergebnis der letzten Aktion. Es läuft höchstens eine Aktion und keine während einer
/// Helper-Installation (`HelperActivityLock`); weitere Aufrufe bleiben dann wirkungslos, die Oberfläche deaktiviert
/// ihre Schaltflächen (`canStart`).
@MainActor
@Observable
public final class ActionRunner {
    /// Ergebnis der letzten Aktion und die Ansicht (`context`), in der sie ausgelöst wurde.
    public struct Result: Equatable, Sendable {
        public let context: ActionContext
        public let presentation: ActionOutcomePresentation
    }

    static let unavailableMessage = "Aktionen sind nicht verfügbar, weil die Überwachung nicht läuft."

    /// `InventoryRecord.id` des Eintrags (beim Wiederherstellen die Beleg-ID), dessen Aktion gerade läuft.
    public private(set) var runningRecordID: String?
    public private(set) var lastResult: Result?
    /// Erhält den Bericht einer Entfernung, sobald der Papierkorb erledigt ist – vor dem Prüfscan und dem Ende der
    /// Aktion (etwa, um entfernte Apps sofort aus der Liste zu nehmen, `TrashedApps`).
    public var onRemovalExecuted: (@MainActor (RemovalReport) -> Void)?

    /// Abbruch der laufenden Aktion: `requested` beendet das Warten auf sie, `finished` meldet, dass die Sperre frei ist.
    private struct Abandonment {
        let requested = OneShotSignal()
        let finished = OneShotSignal()
    }

    /// Gehört zur laufenden Aktion; `nil`, wenn keine läuft.
    private var abandonment: Abandonment?

    /// `nil`, wenn die Überwachung nicht verfügbar ist – Aktionen scheitern dann mit einer Meldung.
    private let coordinator: (any ActionPerforming)?
    /// Schließt Aktionen und die (Neu-)Installation des Helpers gegenseitig aus.
    private let helperActivity: HelperActivityLock

    public init(helperActivity: HelperActivityLock, coordinator: (any ActionPerforming)?) {
        self.coordinator = coordinator
        self.helperActivity = helperActivity
    }

    public var isRunning: Bool { runningRecordID != nil }

    /// Ob eine Aktion beginnen kann: Es läuft weder eine Aktion noch eine Helper-Installation.
    public var canStart: Bool { helperActivity.isIdle }

    /// Ergebnis der letzten Aktion, sofern sie in `context` ausgelöst wurde.
    public func result(in context: ActionContext) -> ActionOutcomePresentation? {
        lastResult?.context == context ? lastResult?.presentation : nil
    }

    public func dismissResult() {
        lastResult = nil
    }

    /// Beendet die laufende Aktion sofort mit dem Ergebnis `.abandoned` und gibt die Sperre frei; kehrt zurück, sobald
    /// sie frei ist. Für „Neu installieren“, wenn die Aktion am nicht erreichbaren Helper hängt
    /// (`HelperActivityLock.maintenanceAccess(helperState:)`). Vor dem Freigeben wird der Task der Aktion abgebrochen:
    /// Ab dann beginnt sie keinen weiteren Schritt (Issue #102). Nur ein schon gesendeter Eingriff läuft im Hintergrund
    /// zu Ende (er scheitert dann am Helper bzw. an dessen Frist); sein spätes Ergebnis wird verworfen. Wartet nicht auf
    /// die Aktion selbst – ein nie zurückkehrender Helper-Aufruf hält die Wartung nicht auf. Ohne laufende Aktion
    /// wirkungslos.
    public func abandonRunningAction() async {
        guard let abandonment else { return }
        abandonment.requested.fire()
        await abandonment.finished.wait()
    }

    /// Wartet, bis der Coordinator keine Aktion mehr ausführt (`ActionCoordinator.drain()`), etwa vor dem Beenden.
    public func drain() async {
        await coordinator?.drain()
    }

    /// Setzt die Berechtigung zurück (nach Bestätigung durch den Nutzer).
    public func reset(_ grant: PermissionGrant, context: ActionContext) async {
        await run(recordID: grant.id, context: context) { coordinator in
            await coordinator.reset(grant)
        } present: { outcome in
            .reset(grant, outcome: outcome)
        }
    }

    /// Setzt den Dienst für alle Apps zurück (nach Bestätigung); `runningRecordID` ist `reset.id`. `false`, wenn die
    /// Aktion nicht begonnen hat.
    @discardableResult
    public func resetService(_ reset: ServiceReset, context: ActionContext) async -> Bool {
        await run(recordID: reset.id, context: context) { coordinator in
            await coordinator.resetService(reset)
        } present: { outcome in
            .resetService(reset, outcome: outcome)
        }
    }

    /// Aktiviert bzw. deaktiviert den Autostart-Eintrag (nach Bestätigung).
    public func setEnabled(_ item: AutostartItem, _ enabled: Bool, context: ActionContext) async {
        await run(recordID: item.id, context: context) { coordinator in
            await coordinator.setEnabled(item, enabled)
        } present: { outcome in
            .setEnabled(item, enabled, outcome: outcome)
        }
    }

    /// Entfernt den Autostart-Eintrag samt Beleg zum Wiederherstellen (nach Bestätigung).
    public func remove(_ item: AutostartItem, context: ActionContext) async {
        await run(recordID: item.id, context: context) { coordinator in
            await coordinator.remove(item)
        } present: { outcome in
            .remove(item, outcome: outcome)
        }
    }

    /// Stellt den entfernten Eintrag aus seinem Beleg wieder her (nach Bestätigung).
    public func restore(_ entry: ReceiptEntry, context: ActionContext) async {
        await run(recordID: entry.id.uuidString, context: context) { coordinator in
            await coordinator.restore(receiptID: entry.id)
        } present: { outcome in
            .restore(entry, outcome: outcome)
        }
    }

    /// Führt die Sicherheitsaktion aus (ohne Bestätigung, nur absichernd); `runningRecordID` ist die `id` der
    /// betroffenen Prüfung.
    public func perform(_ action: SecurityAction, context: ActionContext = .security) async {
        await run(recordID: action.checkKind.rawValue, context: context) { coordinator in
            await coordinator.perform(action)
        } present: { outcome in
            .security(action, outcome: outcome)
        }
    }

    /// Entfernt App bzw. Reste (nach Bestätigung durch den Nutzer); `runningRecordID` ist `plan.id`. Ohne Coordinator
    /// wird nichts verändert (alle Einträge übersprungen). `false`, wenn die Aktion nicht begonnen hat (es lief schon
    /// eine Aktion oder eine Helper-Installation) – dann gibt es auch kein Ergebnis.
    @discardableResult
    public func performRemoval(_ plan: RemovalPlan, context: ActionContext) async -> Bool {
        await run(recordID: plan.id, context: context, unavailable: { .skipping(plan, reason: Self.unavailableMessage) }) { coordinator in
            await coordinator.performRemoval(plan) { report in await self.removalExecuted(report) }
        } present: { report in
            .removal(report)
        }
    }

    /// Räumt aus einer Beobachtung auf (nach Bestätigung, #127): Einzelaktionen und App-Entfernungen nacheinander über den
    /// Coordinator (`ObservationCleanupExecutor`); `runningRecordID` ist `plan.id`. Liefert den Gesamtbericht – nach
    /// `abandonRunningAction()` die bis dahin erledigten Einträge; `nil`, wenn die Aktion nicht begonnen hat.
    @discardableResult
    public func performObservationCleanup(_ plan: ObservationCleanupPlan, context: ActionContext) async -> RemovalReport? {
        var finished: RemovalReport?
        let progress = EntryCollector()
        let unavailable = RemovalReport(
            entries: plan.appRemovals.flatMap { RemovalReport.skipping($0, reason: Self.unavailableMessage).entries }
                + plan.grants.map { .init(subject: .grant($0), result: .skipped(Self.unavailableMessage)) }
                + plan.autostartItems.map { .init(subject: .autostartItem($0), result: .skipped(Self.unavailableMessage)) }
        )
        let started = await run(recordID: plan.id, context: context, unavailable: { unavailable }) { coordinator in
            await ObservationCleanupExecutor(performer: coordinator).run(plan, onEntry: progress.append) { report in
                await self.removalExecuted(report)
            }
        } present: { report in
            finished = report
            return .removal(report)
        }
        guard started else { return nil }
        return finished ?? RemovalReport(entries: progress.entries)
    }

    private func removalExecuted(_ report: RemovalReport) {
        onRemovalExecuted?(report)
    }

    @discardableResult
    func run(
        recordID: String,
        context: ActionContext,
        _ action: @escaping @Sendable (any ActionPerforming) async -> ActionOutcome,
        present: (ActionOutcome) -> ActionOutcomePresentation
    ) async -> Bool {
        await run(recordID: recordID, context: context, unavailable: { .failed(Self.unavailableMessage) }, action, present: present)
    }

    /// Gemeinsamer Ablauf: höchstens eine Aktion, nie während einer Helper-Installation; `unavailable` ohne Coordinator.
    /// `abandonRunningAction()` beendet das Warten vorzeitig (Ergebnis `.abandoned`). `false`, wenn die Aktion nicht
    /// begonnen hat.
    @discardableResult
    func run<Outcome: Sendable>(
        recordID: String,
        context: ActionContext,
        unavailable: () -> Outcome,
        _ action: @escaping @Sendable (any ActionPerforming) async -> Outcome,
        present: (Outcome) -> ActionOutcomePresentation
    ) async -> Bool {
        guard !isRunning, helperActivity.begin(.action) else { return false }
        let abandonment = Abandonment()
        self.abandonment = abandonment
        defer { abandonment.finished.fire() }
        defer { helperActivity.end(.action) }
        runningRecordID = recordID
        lastResult = nil
        defer {
            runningRecordID = nil
            self.abandonment = nil
        }
        guard let coordinator else {
            lastResult = Result(context: context, presentation: present(unavailable()))
            return true
        }
        // Wer zuerst kommt – Ergebnis oder Abbruch –, setzt fort; die Aktion selbst läuft notfalls im Hintergrund weiter.
        let execution = Task { await action(coordinator) }
        let once = ResumeOnce<Outcome?>()
        let outcome: Outcome? = try? await withCheckedThrowingContinuation { continuation in
            guard once.install(continuation) else { return }
            Task { once.resume(.success(await execution.value)) }
            Task {
                await abandonment.requested.wait()
                once.resume(.success(nil))
            }
        }
        // Definierter Übergang vor dem Freigeben der Sperre: Eine abgebrochene Aktion beginnt ab hier keinen weiteren
        // Schritt mehr (der Coordinator löst sein Abbruchsignal synchron aus). Nach regulärem Ende wirkungslos.
        if outcome == nil { execution.cancel() }
        // Gibt den wartenden Abbruch-Task frei, falls die Aktion regulär endete.
        abandonment.requested.fire()
        lastResult = Result(context: context, presentation: outcome.map(present) ?? .abandoned)
        return true
    }
}

/// Sammelt die Einträge eines laufenden Aufräumens threadsicher (`ActionRunner.performObservationCleanup`).
private final class EntryCollector: Sendable {
    private let collected = Mutex<[RemovalReport.Entry]>([])

    var entries: [RemovalReport.Entry] { collected.withLock { $0 } }

    @Sendable func append(_ entry: RemovalReport.Entry) {
        collected.withLock { $0.append(entry) }
    }
}
