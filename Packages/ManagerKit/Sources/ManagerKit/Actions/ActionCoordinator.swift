import Foundation
import os

/// Ergebnis einer Aktion aus Sicht des Nutzers.
public enum ActionOutcome: Hashable, Sendable {
    /// Ausgeführt und im neuen Scan bestätigt.
    case done
    /// Ausgeführt, aber die Wirkung ist (noch) nicht bestätigt; `settingsURL` führt ggf. zur passenden Seite der
    /// Systemeinstellungen.
    case doneButUnverified(String, settingsURL: URL? = nil)
    /// Gescheitert; lesbare deutsche Meldung.
    case failed(String)
}

/// Fordert einen Scan an und liefert dessen Ergebnis; in der App die `MonitoringEngine`.
public protocol ScanRequesting: Sendable {
    /// Fordert einen Scan an und wartet auf den ersten abgeschlossenen Scan, der nicht vor `date` begonnen hat.
    /// `nil`, wenn keiner mehr kommt (Überwachung beendet) oder der wartende Task abgebrochen wird.
    func scan(startedNotBefore date: Date) async -> Snapshot?
}

extension MonitoringEngine: ScanRequesting {
    /// - Note: Vor `start()` liefert die Engine keinen Scan: Der Aufruf wartet dann, bis ein späterer Start scannt
    ///   oder die Engine endet – beim `ActionCoordinator` also die volle Prüffrist (`verificationTimeout`).
    public func scan(startedNotBefore date: Date) async -> Snapshot? {
        // Erst abonnieren, dann anfordern – so geht kein Zustand verloren.
        let states = states()
        await scanNow()
        for await state in states where !state.isScanning {
            if let checkedAt = state.lastCheckedAt, checkedAt >= date, let snapshot = state.snapshot { return snapshot }
        }
        return nil
    }
}

/// Setzt Datenschutz-Berechtigungen zurück; in der App `PermissionActions`.
public protocol PermissionResetting: Sendable {
    func reset(_ grant: PermissionGrant) async throws
    /// Setzt den Dienst für alle Apps zurück (`ServiceReset`).
    func resetService(_ service: String) async throws
}

/// Verändert launchd-Autostart-Einträge; in der App `AutostartActions`.
public protocol AutostartControlling: Sendable {
    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async throws
    func remove(_ item: AutostartItem) async throws -> RemovalReceipt
    func restore(_ receipt: RemovalReceipt) async throws
}

extension PermissionActions: PermissionResetting {}
extension AutostartActions: AutostartControlling {}

/// Führt alle verändernden Aktionen der Oberfläche aus (Spec §5).
///
/// - Es läuft immer nur eine Aktion; weitere warten in Aufrufreihenfolge.
/// - Nach **jeder** Aktion – auch nach einem Fehler – wird neu gescannt: Ein Fehler kann einen Teilzustand
///   hinterlassen, und ein nach dem Senden gescheiterter Helper-Aufruf kann trotzdem gewirkt haben
///   (siehe `PrivilegedAutostartControlling`). Die Wirkung wird am ersten Scan geprüft, der nach dem Ende der Aktion
///   begonnen hat. Bleibt er aus (Zeitüberschreitung) oder scheiterte die zuständige Quelle, lautet das Ergebnis
///   `.doneButUnverified("Überprüfung ausstehend")`.
/// - Nach einem Fehler zählt dieselbe Prüfung: Ist die Änderung im neuen Scan trotzdem wirksam (etwa XPC-Frist
///   abgelaufen, der Helper hat aber entfernt), lautet das Ergebnis `.doneButUnverified` mit diesem Hinweis – beim
///   Entfernen ergänzt darum, dass kein Wiederherstellungsbeleg vorliegt. Sonst bleibt es bei `.failed`.
/// - Eine eingereihte Aktion läuft zu Ende, auch wenn der Aufrufer abgebrochen wird – ein halb ausgeführter Eingriff
///   wäre schlechter als ein verspätetes Ergebnis. Ausnahme beim Beenden: Rein lesende Aktionen („Jetzt suchen“)
///   bricht `drain()` ab bzw. startet sie nicht mehr (Ergebnis „abgebrochen“).
/// - Entfernen speichert einen Wiederherstellungsbeleg im `ReceiptStore`, erfolgreiches Wiederherstellen löscht ihn.
/// - „App entfernen“/„Aufräumen“ (`performRemoval(_:)`) legt Dateien nur über das hereingereichte `TrashPerforming` in
///   den Papierkorb; Vorgabe ist `UnavailableTrash` (löscht nie) – nur die App bindet den Finder an.
/// - Ausnahme vom Durchlaufen: Ein Abbruch des aufrufenden Tasks von `performRemoval(_:onExecuted:)` (bei „Neu
///   installieren“ über `ActionRunner.abandonRunningAction()`) lässt den gerade laufenden Schritt zu Ende laufen; vor
///   jedem weiteren Schritt des Plans wird der Abbruch geprüft (Issue #102).
/// - `drain()` (vor dem Beenden der App) wartet, bis alle eingereihten Aktionen samt Belegspeicherung fertig sind; die
///   Wartezeit auf den Prüfscan entfällt dann (Ergebnis „Überprüfung ausstehend“).
public actor ActionCoordinator {
    public static let defaultVerificationTimeout: Duration = .seconds(30)
    static let pendingVerification = "Überprüfung ausstehend"
    static let effectiveDespiteFailure = "Fehler gemeldet, die Änderung ist aber wirksam."

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "actions")

    private let permissions: any PermissionResetting
    private let autostart: any AutostartControlling
    private let security: any SecurityControlling
    /// Ändert Agenten-Konfigurationen (Stufe 2, `ActionCoordinator+Agents.swift`).
    let agentConfigs: any AgentConfigControlling
    /// Beendet Prozesse hinter Lauschern (#128, `ActionCoordinator+Processes.swift`).
    let processTermination: any ProcessTerminating
    private let receipts: ReceiptStore
    private let scanner: any ScanRequesting
    private let trash: any TrashPerforming
    private let runningApps: any RunningApplicationChecking
    private let removalGuard: RemovalGuard
    private let verificationTimeout: Duration
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    /// Zuletzt eingereihte Aktion; die nächste wartet auf sie.
    private var tail: Task<Void, Never>?
    /// Ausgelöst von `drain()`: Laufende und spätere Wirkungsprüfungen warten nicht mehr auf den Scan.
    private let drainRequested = OneShotSignal()

    public init(
        permissions: any PermissionResetting,
        autostart: any AutostartControlling,
        security: any SecurityControlling,
        agentConfigs: any AgentConfigControlling = AgentConfigActions(),
        processTermination: any ProcessTerminating = UnavailableProcessTermination(),
        receipts: ReceiptStore = ReceiptStore(),
        scanner: any ScanRequesting,
        trash: any TrashPerforming = UnavailableTrash(),
        runningApps: any RunningApplicationChecking = WorkspaceRunningApplications(),
        removalGuard: RemovalGuard = RemovalGuard(),
        verificationTimeout: Duration = ActionCoordinator.defaultVerificationTimeout,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.permissions = permissions
        self.autostart = autostart
        self.security = security
        self.agentConfigs = agentConfigs
        self.processTermination = processTermination
        self.receipts = receipts
        self.scanner = scanner
        self.trash = trash
        self.runningApps = runningApps
        self.removalGuard = removalGuard
        self.verificationTimeout = verificationTimeout
        self.clock = clock
        self.now = now
    }

    // MARK: Aktionen

    /// Setzt die Berechtigung zurück; bestätigt, wenn der Grant (gleiche ID) im neuen Snapshot fehlt.
    public func reset(_ grant: PermissionGrant) async -> ActionOutcome {
        let check = Check(
            source: grant.source,
            unconfirmed: .doneButUnverified(
                "Die Berechtigung ist noch eingetragen – bitte in den Systemeinstellungen entfernen.",
                settingsURL: PermissionCatalog.service(for: grant.service).settingsURL
            )
        ) { snapshot in !snapshot.grants.contains { $0.id == grant.id } }
        return await perform(check) { [permissions] in
            try await permissions.reset(grant)
            return nil
        }
    }

    /// Setzt den Dienst für alle Apps zurück; bestätigt, wenn keine der verwaisten Berechtigungen im neuen Snapshot mehr
    /// vorkommt. Die der installierten Apps verschwinden ebenfalls, geprüft wird aber nur, worum es ging.
    public func resetService(_ reset: ServiceReset) async -> ActionOutcome {
        let orphanIDs = Set(reset.orphans.map(\.id))
        let check = Check(
            source: reset.source,
            unconfirmed: .doneButUnverified(
                "Berechtigungen entfernter Apps sind noch eingetragen.",
                settingsURL: PermissionCatalog.service(for: reset.service).settingsURL
            )
        ) { snapshot in !snapshot.grants.contains { orphanIDs.contains($0.id) } }
        return await perform(check) { [permissions] in
            try await permissions.resetService(reset.service)
            return nil
        }
    }

    /// Aktiviert/deaktiviert; bestätigt, wenn der Eintrag im neuen Snapshot den gewünschten Zustand hat.
    public func setEnabled(_ item: AutostartItem, _ enabled: Bool) async -> ActionOutcome {
        let check = Check(source: item.source, unconfirmed: .doneButUnverified("Die Änderung ist im neuen Scan noch nicht zu sehen.")) { snapshot in
            snapshot.autostartItems.contains { $0.id == item.id && $0.isCurrent && $0.isEnabled == enabled }
        }
        return await perform(check) { [autostart] in
            try await autostart.setEnabled(item, enabled)
            return nil
        }
    }

    /// Entfernt den Eintrag und speichert den Beleg; bestätigt, wenn der Eintrag im neuen Snapshot fehlt.
    public func remove(_ item: AutostartItem) async -> ActionOutcome {
        let check = Check(
            source: item.source,
            unconfirmed: .doneButUnverified("Der Eintrag ist im neuen Scan noch vorhanden."),
            effectiveDespiteFailure: { _ in "\(Self.effectiveDespiteFailure) Kein Wiederherstellungsbeleg vorhanden." }
        ) { snapshot in !snapshot.autostartItems.contains { $0.id == item.id } }
        return await perform(check) { [autostart, receipts, now] in
            let receipt = try await autostart.remove(item)
            do {
                try await receipts.add(receipt, label: item.label, removedAt: now())
                return nil
            } catch {
                return "Entfernt, aber der Wiederherstellungsbeleg wurde nicht gespeichert: \(error.readableDescription)"
            }
        }
    }

    /// Stellt den Eintrag aus dem Beleg wieder her und löscht den Beleg; bestätigt, wenn ein launchd-Eintrag mit dem
    /// Label im neuen Snapshot auftaucht. Scheitert das Wiederherstellen (z. B. `BackupError.superseded`), bleibt
    /// der Beleg erhalten.
    public func restore(receiptID: UUID) async -> ActionOutcome {
        // Das Label eines Belegs ändert sich nie; vorab gelesen, damit auch ein Fehler an ihm geprüft werden kann.
        let label = try? await receipts.entry(id: receiptID)?.receipt.label
        let check = Check(source: .launchd, unconfirmed: .doneButUnverified("Wiederhergestellt, aber im neuen Scan noch nicht zu sehen.")) { snapshot in
            label.map { label in
                snapshot.autostartItems.contains { $0.source == .launchd && $0.isCurrent && $0.label == label }
            } ?? false
        }
        return await perform(check) { [autostart, receipts] in
            guard let entry = try await receipts.entry(id: receiptID) else { throw ActionCoordinatorError.receiptNotFound }
            try await autostart.restore(entry.receipt)
            do {
                try await receipts.remove(id: receiptID)
            } catch {
                Self.logger.error("Beleg nach dem Wiederherstellen nicht gelöscht: \(error.readableDescription, privacy: .public)")
            }
            return nil
        }
    }

    /// Schaltet eine Schutzfunktion ein bzw. sucht Updates; bestätigt, wenn der neue Scan den Zielzustand der
    /// betroffenen Prüfung zeigt (`SecurityActionVerification`). Bezugszeitpunkt für „neu installiert“ bzw. „neu
    /// gesucht“ ist der Aufruf – ein Update, das in der Warteschlange ohnehin eintrifft, zählt mit.
    public func perform(_ action: SecurityAction) async -> ActionOutcome {
        let startedAt = now()
        let check = Check(
            source: .securityPosture,
            unconfirmed: SecurityActionVerification.unconfirmed(action),
            effectiveDespiteFailure: { _ in SecurityActionVerification.effectiveDespiteFailure(action) },
            isConfirmed: { SecurityActionVerification.isConfirmed(action, in: $0, startedAt: startedAt) },
            isEffectiveDespiteFailure: { SecurityActionVerification.isEffectiveDespiteFailure(action, in: $0, startedAt: startedAt) },
            isCancellableWhenQuitting: action.isCancellableWhenQuitting
        )
        return await perform(check) { [security] in
            try await security.perform(action)
            return nil
        }
    }

    /// Entfernt eine App bzw. Reste (Spec v3 §3) über den `RemovalExecutor` und scannt danach in jedem Fall neu (Verlauf
    /// „App entfernt“, aktualisierte Listen). Das Ergebnis je Eintrag steht im Bericht – ob eine Datei im Papierkorb
    /// liegt, prüft schon `TrashPerforming` (existiert der Pfad noch?). Zuvor scannt er neu und gleicht den Plan ab:
    /// Beim Aufräumen bleiben Funde liegen, die inzwischen einer installierten App gehören (`OrphanRecheck`); beim
    /// Entfernen einer App bleibt unberührt, was nach dem neuen Scan auch eine weitere Installation derselben Bundle-ID
    /// träfe oder einer anderen App gehört (#97), ebenso jeder Rest, der nicht mehr allein der App gehört (#100,
    /// `AppRemovalRecheck`). Ohne Scan bleibt alles Geprüfte liegen – auch wenn `drain()` (Beenden der App) den
    /// Abgleichsscan abkürzt: Ein eingereihter Plan beginnt dann keinen Eingriff mehr, ein schon begonnener Eingriff läuft
    /// zu Ende. `onExecuted` erhält den Bericht vor dem Prüfscan.
    ///
    /// Abbruch des aufrufenden Tasks (Issue #102): Der Abbruch-Handler löst das Signal synchron aus, also noch bevor
    /// `Task.cancel()` zurückkehrt; der `RemovalExecutor` prüft es vor jedem weiteren Schritt (`abortedBy`). Ein bereits
    /// an den Helper gesendeter Eingriff läuft weiter (nicht stoppbar), ebenso ein Schritt, der genau in diesem Moment
    /// beginnt – er zählt als laufender Eingriff. Der Prüfscan danach entfällt, damit eine nach „Neu installieren“
    /// gestartete Aktion nicht auf ihn wartet.
    public func performRemoval(
        _ plan: RemovalPlan, onExecuted: @escaping @Sendable (RemovalReport) async -> Void = { _ in }
    ) async -> RemovalReport {
        let abort = OneShotSignal()
        // Der Abgleich vorab endet beim Beenden (`drain()`) wie beim Abbruch des Plans (#102).
        let executor = RemovalExecutor(
            permissions: permissions, autostart: autostart, receipts: receipts, trash: trash, runningApps: runningApps,
            removalGuard: removalGuard,
            currentSnapshot: { [scanner, verificationTimeout, clock, now, drainRequested] in
                await Self.freshSnapshot(
                    from: scanner, startedNotBefore: now(), timeout: verificationTimeout, clock: clock,
                    cutShortBy: drainRequested, abort
                )
            },
            now: now
        )
        return await withTaskCancellationHandler {
            await enqueue { [scanner, verificationTimeout, clock, now, drainRequested] in
                let report = await executor.run(plan, abortedBy: abort)
                await onExecuted(report)
                guard !abort.isFired else { return report }
                _ = await Self.freshSnapshot(
                    from: scanner, startedNotBefore: now(), timeout: verificationTimeout, clock: clock, cutShortBy: drainRequested
                )
                return report
            }
        } onCancel: {
            abort.fire()
        }
    }

    // MARK: Beenden

    /// Wartet, bis keine Aktion mehr läuft oder wartet – auch auf solche, die währenddessen eingereiht werden. Die
    /// Änderung selbst und das Speichern des Belegs laufen vollständig; nur das Warten auf den Prüfscan wird ab jetzt
    /// abgekürzt (`.doneButUnverified("Überprüfung ausstehend")`), auch für später eingereihte Aktionen. Rein lesende
    /// Aktionen (`Check.isCancellableWhenQuitting`) werden abgebrochen bzw. gar nicht erst gestartet. Gedacht für das
    /// Beenden der App, bevor die Überwachung stoppt.
    public func drain() async {
        drainRequested.fire()
        while let current = tail {
            _ = await current.value
            if tail == current { break }
        }
    }

    // MARK: Ablauf

    /// Wie sich die Wirkung einer Aktion im neuen Snapshot zeigt.
    struct Check: Sendable {
        /// Quelle der betroffenen Einträge; scheiterte sie im neuen Scan, ist nichts bestätigt.
        let source: SourceID
        /// Ergebnis nach Erfolg, solange die Wirkung nicht zu sehen ist.
        let unconfirmed: ActionOutcome
        /// Hinweis nach einem Fehler, dessen Änderung trotzdem wirksam ist – je nach Fehler (etwa: Beleg doch vorhanden).
        var effectiveDespiteFailure: @Sendable (any Error) -> String = { _ in ActionCoordinator.effectiveDespiteFailure }
        let isConfirmed: @Sendable (Snapshot) -> Bool
        /// Wirkung nach einem Fehler; `nil` = wie `isConfirmed`.
        var isEffectiveDespiteFailure: (@Sendable (Snapshot) -> Bool)?
        /// Fehler, die belegen, dass die Aktion nichts bewirkt hat: Der Scan wird dann nicht als Wirkung gedeutet.
        var failureRulesOutEffect: @Sendable (any Error) -> Bool = { _ in false }
        /// Rein lesende Aktion: `drain()` bricht sie ab bzw. startet sie nicht mehr.
        var isCancellableWhenQuitting = false

        /// Ergebnis nach Erfolg: `.done`, wenn bestätigt; „Überprüfung ausstehend“ ohne verlässlichen Snapshot;
        /// sonst `unconfirmed`.
        func outcomeAfterSuccess(_ snapshot: Snapshot?) -> ActionOutcome {
            guard let snapshot = reliable(snapshot) else { return .doneButUnverified(ActionCoordinator.pendingVerification) }
            return isConfirmed(snapshot) ? .done : unconfirmed
        }

        /// Ergebnis nach einem Fehler: `.doneButUnverified`, wenn die Änderung in einem verlässlichen Snapshot
        /// trotzdem wirksam ist, sonst `.failed`.
        func outcomeAfterFailure(_ error: any Error, _ snapshot: Snapshot?) -> ActionOutcome {
            !failureRulesOutEffect(error) && reliable(snapshot).map(isEffectiveDespiteFailure ?? isConfirmed) == true
                ? .doneButUnverified(effectiveDespiteFailure(error))
                : .failed(ActionCoordinator.message(for: error))
        }

        /// `snapshot`, sofern vorhanden und `source` darin nicht scheiterte (ihre Einträge wären nur fortgeschrieben).
        private func reliable(_ snapshot: Snapshot?) -> Snapshot? {
            snapshot.flatMap { $0.failedSources.contains(source) ? nil : $0 }
        }
    }

    /// Reiht `action` ein, scannt danach in jedem Fall neu und bewertet das Ergebnis mit `check`. `action` liefert
    /// optional eine Warnung (etwa „Beleg nicht gespeichert“), die nach Erfolg das Ergebnis bestimmt.
    func perform(
        _ check: Check,
        _ action: @escaping @Sendable () async throws -> String?
    ) async -> ActionOutcome {
        await enqueue { [scanner, verificationTimeout, clock, now, drainRequested] in
            let result = await Self.run(action, cancelledBy: check.isCancellableWhenQuitting ? drainRequested : nil)
            let snapshot = await Self.freshSnapshot(
                from: scanner, startedNotBefore: now(), timeout: verificationTimeout, clock: clock,
                cutShortBy: drainRequested
            )
            switch result {
            case .success(let warning?): return .doneButUnverified(warning)
            case .success(nil): return check.outcomeAfterSuccess(snapshot)
            case .failure(let error): return check.outcomeAfterFailure(error, snapshot)
            }
        }
    }

    /// Führt `action` aus. Mit `signal` wird sie abgebrochen, sobald es ausgelöst ist, und startet nicht mehr, wenn es
    /// das schon ist (`CancellationError`); das Ergebnis liegt erst vor, wenn `action` den Abbruch verarbeitet hat.
    private static func run(
        _ action: @escaping @Sendable () async throws -> String?,
        cancelledBy signal: OneShotSignal?
    ) async -> Result<String?, any Error> {
        guard let signal else { return await result(of: action) }
        guard !signal.isFired else { return .failure(CancellationError()) }
        return await withTaskGroup(of: Result<String?, any Error>?.self) { group in
            group.addTask { await result(of: action) }
            group.addTask {
                await signal.wait()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            // Das Signal kam zuerst: auf das Ende der abgebrochenen Aktion warten.
            while let next = await group.next() {
                if let next { return next }
            }
            return .failure(CancellationError())
        }
    }

    private static func result(of action: @Sendable () async throws -> String?) async -> Result<String?, any Error> {
        do {
            return .success(try await action())
        } catch {
            return .failure(error)
        }
    }

    /// Startet `operation`, sobald die zuvor eingereihte Aktion fertig ist. Unstrukturierter Task: Ein Abbruch des
    /// Aufrufers erreicht die Aktion nicht.
    private func enqueue<Outcome: Sendable>(_ operation: @escaping @Sendable () async -> Outcome) async -> Outcome {
        let previous = tail
        let task = Task {
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Erster Snapshot eines Scans, der nicht vor `date` begann; `nil` nach `timeout` auf `clock` oder sobald eines der
    /// `signals` ausgelöst ist.
    private static func freshSnapshot(
        from scanner: any ScanRequesting, startedNotBefore date: Date, timeout: Duration, clock: any Clock<Duration>,
        cutShortBy signals: OneShotSignal...
    ) async -> Snapshot? {
        guard !signals.contains(where: \.isFired) else { return nil }
        return await withTaskGroup(of: Snapshot?.self) { group in
            group.addTask { await scanner.scan(startedNotBefore: date) }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return nil
            }
            for signal in signals {
                group.addTask {
                    await signal.wait()
                    return nil
                }
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// Lesbare deutsche Meldung für jeden Fehler einer Aktion.
    static func message(for error: any Error) -> String {
        error is CancellationError ? "Die Aktion wurde abgebrochen – ihr Ergebnis ist unbekannt." : error.readableDescription
    }
}

/// Fehler des `ActionCoordinator` selbst.
public enum ActionCoordinatorError: LocalizedError, Equatable {
    case receiptNotFound

    public var errorDescription: String? {
        switch self {
        case .receiptNotFound: "Der Wiederherstellungsbeleg wurde nicht gefunden."
        }
    }
}
