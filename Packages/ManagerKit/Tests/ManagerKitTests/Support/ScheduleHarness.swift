import Foundation
import Synchronization
import TestSupport
@testable import ManagerKit

// Aufbau der Tests zur verteilten Komplettprüfung (#649, #662) unter virtueller Zeit.

// MARK: - Testdoubles

/// Quelle mit austauschbarem Beitrag; ist ein Tor gesetzt, hält jeder Aufruf daran an. `starts` meldet jeden Aufruf.
final class AdjustableSource: InventorySource, Sendable {
    let id: SourceID = .tccUser
    let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let contribution: Mutex<InventoryContribution>
    private let gate = Mutex<Gate?>(nil)

    init(_ contribution: InventoryContribution) {
        self.contribution = Mutex(contribution)
        (starts, started) = AsyncStream<Void>.makeStream()
    }

    func set(_ contribution: InventoryContribution) { self.contribution.withLock { $0 = contribution } }
    func hold(at gate: Gate?) { self.gate.withLock { $0 = gate } }

    func collect() async throws -> InventoryContribution {
        started.yield()
        if let gate = gate.withLock({ $0 }) { try await gate.wait() }
        return contribution.withLock { $0 }
    }
}

/// Auslöser auf Abruf, ohne Zeitgeber; `.launch` kommt zuerst.
final class PlainTriggers: ScanTriggering, Sendable {
    private let stream: AsyncStream<ScanReason>
    private let continuation: AsyncStream<ScanReason>.Continuation

    init() {
        (stream, continuation) = AsyncStream<ScanReason>.makeStream()
        continuation.yield(.launch)
    }

    func reasons() async -> AsyncStream<ScanReason> { stream }
    func requestScan() async { send(.manual) }
    func requestScan(only sources: Set<SourceID>) async { send(.sourceRefresh(sources)) }
    func send(_ reason: ScanReason) { continuation.yield(reason) }
}

// MARK: - Aufbau

/// Engine mit Tiefenprüfung unter virtueller Zeit: Wanduhr (`dates`, für Scans und Zeitüberschreitungen) und monotone Uhr
/// (`clock`, für Plan und Prüfalter) laufen gemeinsam, außer ein Test verstellt die Wanduhr. `CountingTreeFingerprint` hält
/// jede vollständige Traversierung mit ihrer monotonen Zeit fest (`elapsed`). Ohne Zeitbudget je Block
/// (`stepBudget: 0`) prüft jeder Schritt genau einen Baum.
struct ScheduleHarness {
    let dates: ManualClock
    let clock = TestClock()
    let trees: CountingTreeFingerprint
    let triggers = PlainTriggers()
    let source: AdjustableSource
    let engine: MonitoringEngine
    let schedule: SignatureRevalidationSchedule

    /// Durchläufe in Blöcken (#662), wenn `walkCost` gesetzt ist; ohne liest jeder Block den ganzen Baum über `trees`.
    let walks: ScriptedTreeWalks?

    /// - Parameters:
    ///   - walkCost: Rechenzeit je Baum für `walks` (Zeitpunkte auf der monotonen Uhr wie `trees`).
    ///   - wallPerCPU: so viel Wanduhr vergeht je Sekunde Rechenzeit eines Abschnitts (gedrosselt etwa 2; 0: keine).
    init(apps: [URL], validator: ScriptedSignatureValidator = ScriptedSignatureValidator(),
         schedule: SignatureRevalidationSchedule = SignatureRevalidationSchedule(stepBudget: 0),
         walkCost: (@Sendable (String) -> Duration)? = nil, wallPerCPU: Double = 0) throws {
        self.schedule = schedule
        let dates = ManualClock()
        self.dates = dates
        let clock = clock
        trees = CountingTreeFingerprint(now: { Self.date(of: clock.now) })
        let walks = walkCost.map { cost in
            ScriptedTreeWalks(cost: cost, now: { Self.date(of: clock.now) },
                              spend: { time in if wallPerCPU > 0 { clock.advance(by: time * wallPerCPU) } })
        }
        self.walks = walks
        source = AdjustableSource(Self.contribution(apps))
        engine = MonitoringEngine(
            coordinator: ScanCoordinator(sources: [source], now: { dates.now }),
            store: try SwiftDataSnapshotStore.inMemory(),
            notifier: ChangeNotifier(notifier: RecordingNotifier(), clock: TestClock()),
            triggers: triggers,
            deepVerifier: DeepSignatureVerifier(validator: validator, now: { dates.now }, clock: clock,
                                                treeFingerprint: trees.reader, treeWalk: walks?.factory),
            now: { dates.now },
            clock: clock,
            signatureSchedule: schedule
        )
    }

    /// Sensible Berechtigung je App: Die Apps sind damit Ziele der Tiefenprüfung.
    static func contribution(_ apps: [URL]) -> InventoryContribution {
        InventoryContribution(grants: apps.map { app in
            let name = app.deletingPathExtension().lastPathComponent
            let client = AppIdentity(
                bundleID: "com.example.\(name)", path: app.path, displayName: name,
                signing: SigningInfo(kind: .developerID, teamID: "T", isNotarized: true), presence: .present
            )
            return TestData.grant("kTCCServiceListenEvent", client: client)
        })
    }

    /// Wanduhr (Scans, `lastCheckedAt`).
    var now: Date { dates.now }
    /// Monotone Zeit als Datum: Zeitpunkte der Komplettprüfungen (`trees`).
    var elapsed: Date { Self.date(of: clock.now) }

    static func date(of instant: TestClock.Instant) -> Date {
        let offset = instant.offset.components
        return Date(timeIntervalSinceReferenceDate: Double(offset.seconds) + Double(offset.attoseconds) / 1e18)
    }

    /// Stellt Datum und Uhr gemeinsam vor; ein Schläfer, dessen Frist erreicht ist, wacht auf.
    func advance(seconds: TimeInterval) {
        dates.advance(by: seconds)
        clock.advance(by: .milliseconds(Int64((seconds * 1_000).rounded())))
    }

    /// Wartet, bis der Plan schläft, und stellt die Zeit bis zu seiner Frist vor, plus `oversleep` (Ruhezustand des
    /// Macs: Der Zeitgeber feuert erst danach). Kehrt erst zurück, wenn der Plan danach wieder schläft – der geweckte
    /// Schritt ist dann vollständig verarbeitet, Prüfungen des Tests sehen keinen halben Stand. Liefert die vorgestellte
    /// Zeit in Sekunden.
    @discardableResult
    func runScheduleStep(oversleep: TimeInterval = 0) async -> TimeInterval? {
        guard let deadline = await clock.nextSleeperDeadline() else { return nil }
        let wait = clock.now.duration(to: deadline)
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18 + oversleep
        advance(seconds: seconds)
        _ = await clock.nextSleeperDeadline()
        return seconds
    }

    /// Meldet, ob Livewerte sichtbar sind (#662), und wartet, bis der geweckte Plan neu geplant hat und wieder schläft.
    /// Nur für einen echten Wechsel aufrufen: Ohne Wechsel weckt die Engine nichts.
    func setLiveViews(visible: Bool) async {
        let before = clock.registrations
        engine.setLiveViewsVisible(visible)
        _ = await clock.nextSleeperDeadline(after: before)
    }

    /// Führt Planschritte aus, bis die monotone Zeit `end` erreicht; `false`, wenn der Plan vorher endet.
    func runSchedule(until end: Date) async -> Bool {
        while elapsed < end {
            guard await runScheduleStep() != nil else { return false }
        }
        return true
    }

    /// Komplettprüfungen je App (Traversierungen) seit `index` im Protokoll.
    func reads(of app: URL, since index: Int = 0) -> Int {
        trees.reads.dropFirst(index).filter { $0.path == app.path }.count
    }
}

/// Vollscan, der zum Zeitpunkt `date` begann, ist abgeschlossen und keine Tiefenprüfung offen.
func settled(at date: Date) -> (MonitoringState) -> Bool {
    { !$0.isScanning && $0.lastCheckedAt == date && $0.pendingSignatureChecks == 0 }
}
