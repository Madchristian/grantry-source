import Combine
import Foundation
import Observation

/// Thermischer Zustand und Energiesparmodus eines Moments – beides ohne Helper und ohne Root lesbar (TM-14.2).
public struct ThermalCondition: Hashable, Sendable {
    public let state: ProcessInfo.ThermalState
    /// Energiesparmodus: macOS senkt Takt und Leistung.
    public let isLowPowerModeEnabled: Bool

    public init(state: ProcessInfo.ThermalState, isLowPowerModeEnabled: Bool) {
        self.state = state
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    public static let nominal = ThermalCondition(state: .nominal, isLowPowerModeEnabled: false)
}

/// Liest den Stand und meldet Wechsel per Benachrichtigung – ohne eigenen Takt (Spec 2026-11-08 §4.4).
public protocol ThermalConditionProviding: Sendable {
    func currentCondition() -> ThermalCondition
    /// Ruft `onChange` nach jedem gemeldeten Wechsel auf dem Hauptthread auf, bis die Rückgabe freigegeben wird.
    func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable
}

/// `ProcessInfo` mit `thermalStateDidChangeNotification` und `NSProcessInfoPowerStateDidChange`.
public struct SystemThermalConditionProvider: ThermalConditionProviding {
    public init() {}

    public func currentCondition() -> ThermalCondition {
        let info = ProcessInfo.processInfo
        return ThermalCondition(state: info.thermalState, isLowPowerModeEnabled: info.isLowPowerModeEnabled)
    }

    public func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> AnyCancellable {
        let center = NotificationCenter.default
        let observers = [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange].map { name in
            // `ProcessInfo` meldet auf einem beliebigen Thread; die Queue `.main` stellt auf dem Hauptthread zu.
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
        return AnyCancellable { observers.forEach { center.removeObserver($0) } }
    }
}

/// Verlauf als Zustandsreihe: nur die Wechsel, jeder gilt bis zum nächsten. Wechsel älter als `span` entfallen bis auf
/// den, der am Beginn des Zeitraums galt; höchstens `maximumChanges` Einträge, auch bei flatterndem Zustand.
public struct ThermalStateHistory: Equatable, Sendable {
    public struct Change: Hashable, Sendable {
        public let time: Date
        public let condition: ThermalCondition

        public init(time: Date, condition: ThermalCondition) {
            self.time = time
            self.condition = condition
        }
    }

    /// Ein Abschnitt gleichen Stands, etwa eine Zelle des Thermikbands.
    public struct Segment: Hashable, Sendable {
        public let start: Date
        public let end: Date
        public let condition: ThermalCondition

        public init(start: Date, end: Date, condition: ThermalCondition) {
            self.start = start
            self.end = end
            self.condition = condition
        }
    }

    static let maximumChanges = 256

    /// Aufsteigend nach Zeit.
    public private(set) var changes: [Change] = []
    public let span: TimeInterval

    public init(span: TimeInterval) {
        self.span = span
    }

    /// Trägt einen Wechsel ein; derselbe Stand wie zuletzt ändert nichts. Eine zurückgestellte Uhr ordnet den Wechsel
    /// am letzten Zeitpunkt ein.
    public mutating func record(_ condition: ThermalCondition, at time: Date) {
        guard changes.last?.condition != condition else { return }
        let time = max(time, changes.last?.time ?? time)
        changes.append(Change(time: time, condition: condition))
        let oldest = time.addingTimeInterval(-span)
        let expired = changes.lastIndex { $0.time <= oldest } ?? 0
        let excess = max(changes.count - Self.maximumChanges, 0)
        changes.removeFirst(max(expired, excess))
    }

    /// Stand zu `time`; `nil` vor dem ersten bekannten Wechsel.
    public func condition(at time: Date) -> ThermalCondition? {
        changes.last { $0.time <= time }?.condition
    }

    /// Abschnitte zwischen `start` und `end`; vor dem ersten bekannten Wechsel bleibt eine Lücke.
    public func segments(from start: Date, to end: Date) -> [Segment] {
        changes.indices.compactMap { index in
            let from = max(changes[index].time, start)
            let to = min(index + 1 < changes.count ? changes[index + 1].time : end, end)
            return from < to ? Segment(start: from, end: to, condition: changes[index].condition) : nil
        }
    }
}

/// Thermischer Zustand und Energiesparmodus als Quelle (TM-14.2): liest den Stand einmal beim Anlegen und danach nur
/// auf eine Wechselbenachrichtigung hin – kein Takt, keine Abfrage je Messtakt. `current` lesen kostet nichts.
@MainActor
@Observable
public final class ThermalStateSource {
    public private(set) var current: ThermalCondition
    public private(set) var history: ThermalStateHistory

    @ObservationIgnored private let provider: any ThermalConditionProviding
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var observation: AnyCancellable?

    /// - Parameter span: Länge des Verlaufs; wie der Verlauf des Task-Managers.
    public init(provider: any ThermalConditionProviding = SystemThermalConditionProvider(),
                now: @escaping @Sendable () -> Date = Date.init,
                span: TimeInterval = TimeInterval(SampleHistory.span.components.seconds)) {
        self.provider = provider
        self.now = now
        let condition = provider.currentCondition()
        current = condition
        history = ThermalStateHistory(span: span)
        history.record(condition, at: now())
        observation = provider.observeChanges { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let condition = provider.currentCondition()
        guard condition != current else { return }
        current = condition
        history.record(condition, at: now())
    }
}
