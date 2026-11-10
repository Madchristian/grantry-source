import Darwin
import Foundation
import Observation

/// Starten und Stoppen im Tab „Dienste“ (Spec 2026-11-06 §6): `prepare` öffnet die Rückfrage nur, wenn die Aktion zum
/// Zustand passt; `confirm` führt sie über den `ActionRunner` aus und liest die Dienste danach neu (`refresh`).
@MainActor
@Observable
public final class ServiceControlFlow {
    /// Auftrag für das Bestätigungsblatt; das Blatt setzt ihn beim Schließen zurück.
    public var pendingRequest: ServiceControlRequest?

    private let actions: ActionRunner
    private let control: ServiceControl
    private let log: (any TaskActionLogging)?
    private let userName: String
    private let now: @Sendable () -> Date
    private let refresh: @MainActor () async -> Void

    /// - Parameters:
    ///   - log: Verlauf für ausgeführte Aktionen (TM-9.5), in der App der `SwiftDataSnapshotStore`.
    ///   - userName: Benutzer, dessen Dienste gesteuert werden, für den Verlauf.
    public init(actions: ActionRunner, control: ServiceControl = ServiceControl(), log: (any TaskActionLogging)? = nil,
                userName: String = UserAccount.shortName(of: getuid()), now: @escaping @Sendable () -> Date = Date.init,
                refresh: @escaping @MainActor () async -> Void) {
        self.actions = actions
        self.control = control
        self.log = log
        self.userName = userName
        self.now = now
        self.refresh = refresh
    }

    /// Ob gerade gesteuert werden kann (keine andere Aktion, keine Helper-Installation).
    public var canStart: Bool { actions.canStart && !actions.isRunning }

    public func prepare(_ action: ServiceControlAction, for row: ServiceRow) {
        guard canStart, row.allows(action), let item = row.autostartItem else { return }
        pendingRequest = ServiceControlRequest(action: action, item: item)
    }

    /// Führt die Aktion aus, vermerkt sie im Verlauf (nur, wenn sie begonnen hat) und liest die Dienste neu.
    public func confirm(_ request: ServiceControlRequest) async {
        if let outcome = await actions.control(request, using: control) {
            await TaskActionHistory.record(request.record(userName: userName, outcome: outcome), in: log, at: now())
        }
        await refresh()
    }
}

extension ServiceRow {
    /// Starten nur, wenn der Dienst nicht läuft, Stoppen nur, wenn er läuft – und beides nur für steuerbare Dienste.
    public func allows(_ action: ServiceControlAction) -> Bool {
        isControllable && autostartItem != nil && (action == .start ? !isRunning : isRunning)
    }
}
