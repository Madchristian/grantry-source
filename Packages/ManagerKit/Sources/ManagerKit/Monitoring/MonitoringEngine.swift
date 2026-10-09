import Foundation
import Synchronization
import os

/// Zustand der Überwachung, wie ihn die App spiegelt.
public struct MonitoringState: Sendable, Equatable {
    /// Letzter bekannter Snapshot: beim Start der gespeicherte, danach das Ergebnis des jüngsten Scans – auch eines
    /// äquivalenten Teilscans, der die Ablage nicht berührt hat. Nach einem Neustart zeigt der Zustand daher den
    /// zuletzt **gespeicherten** Snapshot, bis der erste Scan ihn auffrischt.
    public var snapshot: Snapshot?
    public var findings: [RiskFinding]
    /// Ungefilterte App-Befunde für die technischen Details, auch nach einer Nutzerentscheidung.
    public var appFindings: [RiskFinding] = []
    public var acceptedAppIDs: Set<String> = []
    public var riskAcceptanceError: String?
    /// Beginn des letzten abgeschlossenen Vollscans – auch wenn er nichts Neues ergab (Teilscans zählen nicht).
    public var lastCheckedAt: Date?
    public var isScanning: Bool
    public var unreadCount: Int
    /// Die jüngsten Events (höchstens `MonitoringEngine.recentEventsLimit`), neueste zuerst.
    public var recentEvents: [HistoryEvent]
    /// Quellen, die ein Vollscan fragt (`ScanCoordinator.sourceIDs`); bestimmt, welche Abdeckung je Bereich erwartet
    /// wird (#142). `nil`: unbekannt – dann gelten alle Quellen eines Bereichs als erwartet.
    public var activeSources: Set<SourceID>?

    public init(
        snapshot: Snapshot? = nil,
        findings: [RiskFinding] = [],
        lastCheckedAt: Date? = nil,
        isScanning: Bool = false,
        unreadCount: Int = 0,
        recentEvents: [HistoryEvent] = [],
        activeSources: Set<SourceID>? = nil
    ) {
        self.snapshot = snapshot
        self.findings = findings
        self.lastCheckedAt = lastCheckedAt
        self.isScanning = isScanning
        self.unreadCount = unreadCount
        self.recentEvents = recentEvents
        self.activeSources = activeSources
    }
}

/// Liefert Scan-Auslöser; in der App `ScanTriggers`, in Tests steuerbar.
public protocol ScanTriggering: Sendable {
    associatedtype Reasons: AsyncSequence<ScanReason, Never> & Sendable
    /// Strom der Auslöser; genau ein Konsument.
    func reasons() async -> Reasons
    /// Fordert sofort einen Scan an.
    func requestScan() async
    /// Fordert sofort einen Teilscan nur der Quellen `sources` an (`ScanReason.sourceRefresh`).
    func requestScan(only sources: Set<SourceID>) async
}

extension ScanTriggers: ScanTriggering {}

/// Orchestriert die Überwachung: Auslöser → `ScanCoordinator` → `SnapshotDiffer` → `SnapshotStore` →
/// `ChangeNotifier`, und veröffentlicht den Zustand als Strom. Alle Änderungen landen im Verlauf; gemeldet wird nur,
/// was die `NotificationPolicy` zulässt.
///
/// Es läuft nie mehr als ein Scan; Auslöser, die währenddessen eintreffen, ergeben genau einen Folgescan (siehe
/// `run`). Fehler der Ablage werden protokolliert, der Zustand im Speicher bleibt trotzdem aktuell.
///
/// Tiefe Signaturprüfung (optional, `deepVerifier`): Nach jedem Scan fließen bereits bekannte Ergebnisse (Cache pro
/// Fingerabdruck) sofort in die Findings ein; neue oder veränderte Ziele (`InvalidSignatureRule.verificationTargets`)
/// prüft eine Hintergrund-Task nacheinander, und jedes Ergebnis, das die Findings ändert, wird nachveröffentlicht.
/// Scans warten nie auf diese Prüfungen.
///
/// Lebenszyklus: `idle` → `starting` → `running` → `stopped`, wobei `stopped` endgültig ist – `ScanTriggers` liefert
/// seinen Strom nur einem Konsumenten. `start()` und `stop()` setzen den Übergang vor ihrem ersten `await`, deshalb
/// starten gleichzeitige Aufrufe nur eine Schleife, und ein `stop()` während des Starts bricht diesen ab.
public actor MonitoringEngine {
    /// Zahl der Events in `MonitoringState.recentEvents`.
    public static let recentEventsLimit = 20
    /// Events, die älter sind, werden gelöscht (`SnapshotStore.pruneEvents`).
    public static let eventRetention: TimeInterval = 90 * 24 * 3_600
    /// Mindestabstand zwischen zwei Bereinigungen.
    static let pruneInterval: TimeInterval = 24 * 3_600

    private enum Lifecycle {
        case idle, starting, running, stopped
    }

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "monitoring")

    private let coordinator: ScanCoordinator
    private let store: any SnapshotStore
    private let notifier: ChangeNotifier
    private let triggers: any ScanTriggering
    private let evaluator: RiskEvaluator
    private let differ: SnapshotDiffer
    private let notificationPolicy: NotificationPolicy
    private let deepVerifier: DeepSignatureVerifier?
    private let now: @Sendable () -> Date
    private var appRiskAcceptances: AppRiskAcceptanceStore

    private var state = MonitoringState()
    /// Der Snapshot, wie er zuletzt nachweislich in der Ablage lag (geladen, gespeichert oder aufgefrischt); `nil`,
    /// solange keiner gespeichert ist. Grundlage für `persistSightings()`.
    private var storedSnapshot: Snapshot?
    private let subscribers = StateBroadcaster<MonitoringState>()
    private var lifecycle = Lifecycle.idle
    private var startup: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var lastPrunedAt: Date?
    /// Ergebnisse der tiefen Signaturprüfung für die Ziele des aktuellen Snapshots.
    private var signatureVerdicts: [String: DeepSignatureVerdict] = [:]
    /// Ziele des aktuellen Snapshots; Ergebnisse für andere Pfade werden verworfen.
    private var verificationTargets: Set<String> = []
    /// Noch zu prüfende Ziele, in Prüfreihenfolge.
    private var pendingVerifications: [String] = []
    private var verification: Task<Void, Never>?

    public init(
        coordinator: ScanCoordinator,
        store: any SnapshotStore,
        notifier: ChangeNotifier,
        triggers: any ScanTriggering,
        evaluator: RiskEvaluator = .standard,
        differ: SnapshotDiffer = SnapshotDiffer(),
        notificationPolicy: NotificationPolicy = NotificationPolicy(),
        deepVerifier: DeepSignatureVerifier? = nil,
        appRiskAcceptances: AppRiskAcceptanceStore = AppRiskAcceptanceStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.store = store
        self.notifier = notifier
        self.triggers = triggers
        self.evaluator = evaluator
        self.differ = differ
        self.notificationPolicy = notificationPolicy
        self.deepVerifier = deepVerifier
        self.appRiskAcceptances = appRiskAcceptances
        self.now = now
        state.activeSources = coordinator.sourceIDs
    }

    /// Lädt den gespeicherten Zustand und beginnt, Auslöser zu verarbeiten. Kehrt zurück, sobald die Engine läuft;
    /// der erste Scan (`.launch`) folgt danach. Einmalig: Nach `stop()` ist ein weiterer Aufruf wirkungslos.
    /// Ein gleichzeitiger zweiter Aufruf startet nichts, sondern wartet den ersten mit ab.
    public func start() async {
        switch lifecycle {
        case .idle:
            lifecycle = .starting
            let startup = Task { await self.startUp() }
            self.startup = startup
            await startup.value
        case .starting:
            await startup?.value
        case .running:
            return
        case .stopped:
            Self.logger.notice("start() nach stop() ist wirkungslos: Die Engine läuft nur einmal.")
        }
    }

    /// Beendet die Verarbeitung endgültig: Ein laufender Scan wird abgebrochen und nicht gespeichert, die
    /// Sichtungszeiten ruhiger Teilscans werden gesichert (`persistSightings()`), wartende Benachrichtigungen werden
    /// sofort gemeldet, alle `states()`-Ströme enden. Kehrt zurück, wenn nichts mehr läuft; einen laufenden `start()`
    /// bricht `stop()` ab und wartet ihn ab. Einzige Ausnahme: Eine gerade laufende tiefe Signaturprüfung lässt sich
    /// nicht abbrechen und dauert bei großen Apps Minuten – `stop()` wartet sie nicht ab, ihr Ergebnis wird verworfen.
    public func stop() async {
        let previous = lifecycle
        lifecycle = .stopped
        verification?.cancel()
        verification = nil
        switch previous {
        case .stopped:
            return
        case .starting:
            await startup?.value
        case .idle, .running:
            break
        }
        if let loop {
            self.loop = nil
            loop.cancel()
            await loop.value
        }
        await persistSightings()
        await notifier.flushNow()
        subscribers.finish()
    }

    public func scanNow() async {
        await triggers.requestScan()
    }

    /// Teilscan: liest nur die Quellen `sources` neu (etwa die Lauscher nach „Der Dienst läuft nicht mehr.“).
    public func scanNow(only sources: Set<SourceID>) async {
        await triggers.requestScan(only: sources)
    }

    public func markAllRead() async {
        do {
            try await store.markAllRead()
        } catch {
            Self.logger.error("Events nicht als gelesen markiert: \(error.readableDescription, privacy: .public)")
        }
        await refreshHistory()
        publish()
    }

    /// Speichert vor Veröffentlichung der neuen Bewertung. Bei Fehler bleibt die bisherige Entscheidung sichtbar.
    public func setAppRiskAccepted(_ accepted: Bool, appID: String) async throws {
        guard let snapshot = state.snapshot,
              let app = snapshot.installedApps.first(where: { $0.id == appID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try appRiskAcceptances.setAccepted(accepted, for: app)
        state.findings = findings(for: snapshot)
        publish()
        if accepted { await notifier.discardAppNotifications(for: [appID]) }
    }

    /// Aktueller Zustand sofort, danach jede Änderung; ein Abonnent, der nicht mitkommt, erhält den jüngsten Zustand.
    /// Mit `stop()` enden alle Ströme; danach liefert ein neuer nur noch den letzten Zustand.
    public func states() -> AsyncStream<MonitoringState> {
        subscribers.subscribe(initial: state)
    }

    /// Zahl der offenen Abonnements (für Tests).
    nonisolated var subscriberCount: Int { subscribers.count }

    // MARK: Start und Schleife

    /// Lädt den Zustand aus der Ablage, holt den Auslöserstrom und startet die Schleife. Kam inzwischen `stop()`,
    /// endet der Start nach dem laufenden Schritt; ein schon geholter Strom wird dann durch Abbruch der Schleife
    /// beendet, damit `ScanTriggers` Beobachtung und Zeitgeber freigibt.
    private func startUp() async {
        await loadPersistedState()
        guard lifecycle == .starting else { return }
        publish()
        let feed = await triggers.reasons()
        let loop = Task { await self.run(feed) }
        guard lifecycle == .starting else {
            loop.cancel()
            await loop.value
            return
        }
        self.loop = loop
        lifecycle = .running
    }

    /// Leitet die Auslöser in die Scan-Schleife. Was während eines Scans eintrifft, verdichtet sich über
    /// `ScanReason.merging` auf genau einen Folgescan – ein Teilscan verdrängt so nie einen wartenden Vollscan. Beide
    /// Hälften laufen als Kinder einer Task-Gruppe; endet der Zulauf, läuft die Schleife leer, ein Abbruch beendet
    /// beide.
    private nonisolated func run(_ feed: some AsyncSequence<ScanReason, Never> & Sendable) async {
        let pending = Mutex<ScanReason?>(nil)
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await reason in feed {
                    pending.withLock { $0 = $0.map { $0.merging(reason) } ?? reason }
                    continuation.yield()
                }
                continuation.finish()
            }
            group.addTask {
                for await _ in signals {
                    guard !Task.isCancelled else { break }
                    guard let reason = pending.withLock({ $0.take() }) else { continue }
                    await self.performScan(reason: reason)
                }
            }
        }
    }

    /// Vollscan mit Fortschrittsanzeige und neuem Prüfzeitpunkt; ein Teilscan (`ScanReason.refreshedSources`) läuft
    /// still – ohne `isScanning` und ohne neuen Prüfzeitpunkt (weder `lastCheckedAt` noch in der Ablage), sonst
    /// blinkte alle 60 s der Fortschritt und „Zuletzt geprüft“ verlöre seine Bedeutung (Sicherheitsscan). Ohne
    /// bekannten Snapshot ist ein Teilscan in Wahrheit ein Vollscan und wird auch so behandelt.
    ///
    /// Ein ruhiger Teilscan (äquivalent zum Vorgänger, gleiche Findings, gleiche Quellenfehler und -einschränkungen)
    /// frischt nur `state.snapshot` auf – das hält `lastSeenAt` der Lauscher für die Entprellung aktuell –,
    /// veröffentlicht aber nichts und lässt Ablage, Bereinigung und Verlauf aus: Jeder neue Zustand löst in der App
    /// Arbeit aus, das soll nicht jede Minute passieren. Die aufgefrischten Sichtungszeiten landen mit dem nächsten
    /// Vollscan (`persist`) oder spätestens beim Stopp (`persistSightings()`) in der Ablage, damit ein Neustart nicht
    /// mit veralteten Sichtungen entprellt. Fehler und Einschränkungen zählen eigens, weil sie die Äquivalenz nicht
    /// berühren: Fällt etwa der Helper weg, kommt „nur eigene Sockets“ hinzu, während fremde Lauscher fortgeschrieben
    /// werden – der Hinweis soll sofort erscheinen, nicht erst mit dem nächsten Vollscan.
    private func performScan(reason: ScanReason) async {
        let only = reason.refreshedSources
        let isFullScan = only == nil || state.snapshot == nil
        if isFullScan {
            // `.notice` wird persistiert; je tatsächlichem Vollscan genau ein Eintrag (Auslöser sind entprellt und
            // zusammengefasst). Teilscans kommen alle 60 s und landen daher nur als `.debug` im Protokoll.
            Self.logger.notice("Scan: \(reason.description, privacy: .public)")
            state.isScanning = true
            publish()
        } else {
            Self.logger.debug("Teilscan: \(reason.description, privacy: .public)")
        }
        var publishes = isFullScan
        defer {
            if isFullScan { state.isScanning = false }
            if publishes { publish() }
        }

        let previous = state.snapshot
        let current: Snapshot
        do {
            current = try await coordinator.scan(previous: previous, only: isFullScan ? nil : only)
        } catch {
            return  // Abbruch durch `stop()`: nichts speichern, die Schleife endet.
        }
        state.snapshot = current
        await refreshSignatureVerdicts(for: current)
        let findings = findings(for: current)
        if !isFullScan, let previous, current.isEquivalent(to: previous), findings == state.findings,
           current.sourceLimitations == previous.sourceLimitations, current.sourceErrors == previous.sourceErrors {
            startPendingVerifications()
            return
        }
        publishes = true
        state.findings = findings
        if isFullScan { state.lastCheckedAt = current.takenAt }
        await persist(current, previous: previous, checkedAt: isFullScan ? current.takenAt : nil)
        await pruneIfDue()
        await refreshHistory()
        startPendingVerifications()
    }

    // MARK: Tiefe Signaturprüfung

    /// Übernimmt die noch gültigen Ergebnisse für die Ziele von `snapshot` aus dem Cache des Verifiers und merkt die
    /// übrigen zur Prüfung vor.
    private func refreshSignatureVerdicts(for snapshot: Snapshot) async {
        guard let deepVerifier else { return }
        let targets = InvalidSignatureRule.verificationTargets(in: snapshot)
        let cached = await deepVerifier.cachedVerdicts(for: targets)
        verificationTargets = Set(targets)
        signatureVerdicts = cached
        pendingVerifications = targets.filter { cached[$0] == nil }
    }

    /// Startet die Hintergrund-Prüfung, sofern Ziele offen sind und sie nicht schon läuft. Sie arbeitet
    /// `pendingVerifications` nacheinander ab – auch Ziele, die ein späterer Scan währenddessen vormerkt.
    private func startPendingVerifications() {
        guard deepVerifier != nil, verification == nil, !pendingVerifications.isEmpty, lifecycle != .stopped else { return }
        verification = Task { await self.drainPendingVerifications() }
    }

    private func drainPendingVerifications() async {
        defer { verification = nil }
        while let deepVerifier, !Task.isCancelled, !pendingVerifications.isEmpty {
            let path = pendingVerifications.removeFirst()
            let verdict = await deepVerifier.verify(path: path)
            guard !Task.isCancelled else { return }
            record(verdict, for: path)
        }
    }

    /// Übernimmt ein Prüfergebnis und veröffentlicht den Zustand, wenn sich die Findings dadurch ändern.
    private func record(_ verdict: DeepSignatureVerdict, for path: String) {
        guard verificationTargets.contains(path), let snapshot = state.snapshot else { return }
        signatureVerdicts[path] = verdict
        let previousAppFindings = state.appFindings
        let updated = findings(for: snapshot)
        guard updated != state.findings || previousAppFindings != state.appFindings else { return }
        state.findings = updated
        publish()
    }

    private func findings(for snapshot: Snapshot) -> [RiskFinding] {
        let all = evaluator.evaluate(snapshot, signatures: signatureVerdicts)
        let appIDs = Set(snapshot.installedApps.map(\.id))
        state.appFindings = all.filter { appIDs.contains($0.recordID) }
        do {
            state.acceptedAppIDs = try appRiskAcceptances.acceptedIDs(in: snapshot.installedApps)
            state.riskAcceptanceError = nil
        } catch {
            state.acceptedAppIDs = []
            state.riskAcceptanceError = "Akzeptierte App-Risiken konnten nicht geladen oder gespeichert werden: \(error.readableDescription)"
        }
        return all.filter { !state.acceptedAppIDs.contains($0.recordID) }
    }

    /// Äquivalenter Vollscan: Der aufgefrischte Snapshot (Sichtungszeiten der Lauscher) ersetzt den gespeicherten,
    /// ohne Events, samt Prüfzeitpunkt `checkedAt`; ein äquivalenter Teilscan (`checkedAt == nil`) speichert nichts,
    /// sein Snapshot bleibt im Speicher (siehe `MonitoringState.snapshot`, `persistSightings()`). Sonst werden Snapshot
    /// und Events gespeichert – bei `checkedAt == nil` mit dem bisherigen Prüfzeitpunkt – und die Änderungen gemeldet,
    /// soweit die `NotificationPolicy` sie zulässt. Fremde Lauscher der ersten vollständigen Lieferung fehlen in
    /// beidem (`NetworkListenerBaseline`).
    ///
    /// Scheitert das Speichern, werden die Änderungen trotzdem gemeldet, fehlen aber im Verlauf. Bleibt `record`
    /// dauerhaft kaputt, vergleicht der nächste Start wieder mit dem zuletzt gespeicherten Snapshot – dieselbe
    /// Änderung wird dann erneut gemeldet.
    private func persist(_ current: Snapshot, previous: Snapshot?, checkedAt: Date?) async {
        if let previous, current.isEquivalent(to: previous) {
            guard let checkedAt else { return }
            await touch(current, checkedAt: checkedAt)
            return
        }
        let events = NetworkListenerBaseline.filtering(differ.diff(from: previous, to: current), previous: previous,
                                                       current: current)
        let history: [HistoryEvent]
        do {
            history = try await store.record(current, events: events, checkedAt: checkedAt)
            storedSnapshot = current
        } catch {
            Self.logger.error("Snapshot nicht gespeichert: \(error.readableDescription, privacy: .public)")
            history = events.map { HistoryEvent(id: UUID(), event: $0, isRead: false) }
        }
        let notifiable = history.filter {
            if case .installedApp(let app) = $0.event.subject,
               (try? appRiskAcceptances.isAccepted(app)) == true { return false }
            return notificationPolicy.shouldNotify($0.event)
        }
        if !notifiable.isEmpty {
            await notifier.notify(notifiable)
        }
    }

    /// Ersetzt den gespeicherten Snapshot durch den äquivalenten `snapshot` (`SnapshotStore.touch`).
    private func touch(_ snapshot: Snapshot, checkedAt: Date?) async {
        do {
            try await store.touch(snapshot, checkedAt: checkedAt)
            storedSnapshot = snapshot
        } catch {
            Self.logger.error("Snapshot nicht aufgefrischt: \(error.readableDescription, privacy: .public)")
        }
    }

    /// Sichert beim Stopp die Sichtungszeiten, die ruhige Teilscans nur im Speicher aufgefrischt haben – sonst
    /// entprellte der nächste Start mit veralteten Sichtungen und meldete einen kurz unterbrochenen Dienst als
    /// „beendet“ und danach als „neu“. Nur ein zum gespeicherten äquivalenter Snapshot wird geschrieben: Ist `record`
    /// gescheitert, bleibt der gespeicherte Vergleichsstand, damit die ungespeicherte Änderung erneut gemeldet wird.
    private func persistSightings() async {
        guard let snapshot = state.snapshot, let storedSnapshot, snapshot != storedSnapshot,
              snapshot.isEquivalent(to: storedSnapshot) else { return }
        await touch(snapshot, checkedAt: nil)
    }

    private func pruneIfDue() async {
        let now = now()
        if let lastPrunedAt, now.timeIntervalSince(lastPrunedAt) < Self.pruneInterval { return }
        lastPrunedAt = now
        do {
            try await store.pruneEvents(olderThan: now.addingTimeInterval(-Self.eventRetention))
        } catch {
            Self.logger.error("Verlauf nicht bereinigt: \(error.readableDescription, privacy: .public)")
        }
    }

    // MARK: Zustand

    private func loadPersistedState() async {
        do {
            state.snapshot = try await store.latestSnapshot()
            storedSnapshot = state.snapshot
            state.findings = state.snapshot.map(findings) ?? []
            state.lastCheckedAt = try await store.lastCheckedAt()
        } catch {
            Self.logger.error("Gespeicherter Snapshot nicht geladen: \(error.readableDescription, privacy: .public)")
        }
        await refreshHistory()
    }

    /// Holt `recentEvents` und `unreadCount` aus der Ablage; bei Fehlern bleiben die bisherigen Werte.
    private func refreshHistory() async {
        do {
            state.recentEvents = try await store.events(limit: Self.recentEventsLimit)
            state.unreadCount = try await store.unreadCount()
        } catch {
            Self.logger.error("Verlauf nicht geladen: \(error.readableDescription, privacy: .public)")
        }
    }

    private func publish() {
        subscribers.send(state)
    }
}

/// Verteilt Zustände an beliebig viele Abonnenten. Jeder Strom liefert sofort den Anfangszustand und danach jeden
/// gesendeten; er puffert nur den jüngsten. Endet ein Strom (Abbruch des Konsumenten), wird sein Abonnement noch im
/// Termination-Handler entfernt – deshalb eine Sperre statt Actor-Isolation. Nach `finish()` enden alle Ströme, und
/// neue Abonnements liefern nur noch ihren Anfangszustand.
final class StateBroadcaster<State: Sendable>: Sendable {
    private struct Registry {
        var nextID = 0
        var continuations: [Int: AsyncStream<State>.Continuation] = [:]
        var isFinished = false
    }

    private let registry = Mutex(Registry())

    var count: Int { registry.withLock { $0.continuations.count } }

    func subscribe(initial: State) -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id: Int? = registry.withLock { registry in
            guard !registry.isFinished else { return nil }
            defer { registry.nextID += 1 }
            registry.continuations[registry.nextID] = continuation
            return registry.nextID
        }
        if let id {
            continuation.onTermination = { [weak self] _ in
                _ = self?.registry.withLock { $0.continuations.removeValue(forKey: id) }
            }
        }
        continuation.yield(initial)
        if id == nil { continuation.finish() }
        return stream
    }

    func send(_ state: State) {
        let continuations = registry.withLock { Array($0.continuations.values) }
        for continuation in continuations {
            continuation.yield(state)
        }
    }

    func finish() {
        let continuations = registry.withLock { registry in
            registry.isFinished = true
            defer { registry.continuations = [:] }
            return Array(registry.continuations.values)
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}
