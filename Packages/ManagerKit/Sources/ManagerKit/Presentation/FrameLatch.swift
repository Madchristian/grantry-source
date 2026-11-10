import Observation

/// Hält den Stand einer eigenen Messung (Sensoren des Helpers, `ps`) bis zum nächsten Takt des Task-Managers zurück
/// (#481): Jede Änderung, die eine Ansicht liest, wertet sie samt Layout neu aus. Ungetaktet liefen „Übersicht“,
/// „Leistung“ und „Chip“ so bis zu zweimal je Takt durch; mit dem Angebot im Takt (`TaskManagerModel.onFrame`) kommt
/// der neue Stand in derselben Aktualisierung wie der Takt an.
@MainActor
@Observable
public final class FrameLatch<Value> {
    public private(set) var value: Value
    /// Ob ein angebotener Stand neu ist (zweites Argument) gegenüber dem gehaltenen (erstes Argument).
    @ObservationIgnored private let isNew: (Value, Value) -> Bool

    public init(_ value: Value, isNew: @escaping (Value, Value) -> Bool) {
        self.value = value
        self.isNew = isNew
    }

    /// Übernimmt `next`, wenn er neu ist; sonst bleibt alles still.
    public func offer(_ next: Value) {
        if isNew(value, next) { value = next }
    }
}
