import AppKit
import Observation

/// Einstellung „Wachbuch führen“ und Lebenszyklus des Recorders (Spec 2026-11-08 §5.1, TM-12.3). Standard ist aus
/// (Entscheidung O1, bis TM-12.7 das Hintergrundbudget am signierten Kandidaten belegt); aus heißt kein Takt und keine
/// Datei. Die Einstellung wirkt ab `activate()` (App-Start); Ruhezustand und Aufwachen meldet `NSWorkspace`, Thermik
/// und Energiesparmodus die gemeinsame `ThermalStateSource` des Task-Managers. Änderungen aus dem Verlauf kommen beim
/// Einschalten als Nachtrag aus `history` und danach je Scan (`recordChanges`). Alle Aufrufe gehen in Reihenfolge an den
/// Recorder, der außerhalb des Main Actors arbeitet.
@MainActor
@Observable
public final class WatchbookModel {
    public static let storageKey = "watchbook.isEnabled"
    static let sinceStorageKey = "watchbook.recordingSince"

    private var isEnabledValue: Bool
    /// Seit wann „Wachbuch führen“ an ist („Aufzeichnung an seit …“, TM-12.5); `nil`, wenn aus oder vor TM-12.5
    /// eingeschaltet.
    public private(set) var recordingSince: Date?
    @ObservationIgnored private let recorder: any WatchbookRecording
    @ObservationIgnored private let thermal: ThermalStateSource?
    /// Verlauf für den Nachtrag beim Einschalten.
    @ObservationIgnored private let history: (any SnapshotStore)?
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Verlaufseinträge, die schon an den Recorder gingen (Stand des letzten Scans).
    @ObservationIgnored private var forwardedChanges: Set<UUID> = []
    /// Datenträger-Befunde, die schon an den Recorder gingen; leer, solange nicht aufgezeichnet wird.
    @ObservationIgnored private var forwardedStorageFindings: [SystemFinding] = []
    @ObservationIgnored private var isActive = false
    /// Letzter Aufruf an den Recorder; der nächste wartet auf ihn.
    @ObservationIgnored private var lastCall: Task<Void, Never>?
    @ObservationIgnored private var sleepObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var thermalForwarding: Task<Void, Never>?

    public init(recorder: any WatchbookRecording, thermal: ThermalStateSource? = nil, history: (any SnapshotStore)? = nil,
                settings: any SettingsStore = UserDefaults.standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.recorder = recorder
        self.thermal = thermal
        self.history = history
        self.settings = settings
        self.now = now
        isEnabledValue = settings.bool(forKey: Self.storageKey)
        recordingSince = isEnabledValue ? settings.object(forKey: Self.sinceStorageKey) as? Date : nil
    }

    isolated deinit {
        sleepObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        thermalForwarding?.cancel()
    }

    /// „Wachbuch führen“ – Bindung der Einstellung.
    public var isEnabled: Bool {
        get { isEnabledValue }
        set {
            guard newValue != isEnabledValue else { return }
            isEnabledValue = newValue
            recordingSince = newValue ? now() : nil
            settings.set(newValue, forKey: Self.storageKey)
            settings.set(recordingSince, forKey: Self.sinceStorageKey)
            guard isActive else { return }
            call { await $0.setEnabled(newValue) }
            if newValue { backfillChanges() }
        }
    }

    /// Ab dem App-Start: zeichnet auf, solange `isEnabled` gilt, und folgt Ruhezustand und Aufwachen.
    public func activate() {
        guard !isActive else { return }
        isActive = true
        observeSleep()
        forwardThermalCondition()
        guard isEnabledValue else { return }
        call { await $0.setEnabled(true) }
        backfillChanges()
    }

    /// Nach jedem Scan die neuesten Verlaufseinträge (`MonitoringState.recentEvents`): Weiter gehen nur die, die beim
    /// letzten Scan noch nicht dabei waren – so liest nicht jeder Scan das Wachbuch.
    public func recordChanges(_ recent: [HistoryEvent]) {
        let fresh = recent.filter { !forwardedChanges.contains($0.id) }
        forwardedChanges = Set(recent.map(\.id))
        guard isActive, isEnabledValue, !fresh.isEmpty else { return }
        call { await $0.recordChanges(fresh) }
    }

    /// Nach jeder Prüfung des Volume-Inventars die laufenden Datenträger-Befunde (TM-15.5): Weiter gehen neue und
    /// widerlegte (`FindingRules.storageChanges`). Ausgeschaltet geht nichts weiter; nach dem Einschalten beginnt bei der
    /// nächsten Prüfung, was dann läuft.
    public func recordStorageFindings(_ current: [SystemFinding], at time: Date) {
        guard isActive, isEnabledValue else {
            forwardedStorageFindings = []
            return
        }
        let events = FindingRules.storageChanges(from: forwardedStorageFindings, to: current, at: time)
            .map(\.watchbookEvent)
        forwardedStorageFindings = current
        guard !events.isEmpty else { return }
        call { await $0.recordFindings(events) }
    }

    /// Beim Beenden der App: schreibt alles Offene und beendet die Aufzeichnung.
    public func stop() async {
        call { await $0.shutdown() }
        await settle()
    }

    /// Aufbewahrung und Obergrenze einhalten, auch wenn das Wachbuch aus ist (täglich, mit dem App-Verlauf).
    public func enforceRetention() {
        call { await $0.enforceRetention() }
    }

    func systemWillSleep() {
        call { await $0.systemWillSleep() }
    }

    func systemDidWake() {
        call { await $0.systemDidWake() }
    }

    /// Wartet, bis alle bisher veranlassten Aufrufe erledigt sind.
    func settle() async {
        await lastCall?.value
    }

    private func call(_ operation: @escaping @Sendable (any WatchbookRecording) async -> Void) {
        let previous = lastCall, recorder = recorder
        lastCall = Task {
            await previous?.value
            await operation(recorder)
        }
    }

    /// Nachtrag beim Einschalten: Änderungen der Aufbewahrungszeit aus dem Verlauf, nur als Marken.
    private func backfillChanges() {
        guard let history else { return }
        let now = now
        call { recorder in
            guard let events = try? await WatchbookChangeMarks.history(from: history, now: now()) else { return }
            await recorder.recordChanges(events)
        }
    }

    /// Den Stand sofort und danach jeden Wechsel – die Quelle liest selbst nur auf Benachrichtigung hin.
    private func forwardThermalCondition() {
        guard let thermal else { return }
        thermalForwarding = Task { [weak self] in
            for await condition in Observations({ thermal.current }) {
                self?.call { await $0.setThermalCondition(condition) }
            }
        }
    }

    /// Nur volle Ruhe- und Aufwachvorgänge; Wartungs-Aufwachen (Dark Wake) melden sie nicht.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
        ]
    }
}
