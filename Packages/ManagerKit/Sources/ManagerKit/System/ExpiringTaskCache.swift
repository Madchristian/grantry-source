import Foundation

/// Zwischenspeicher für asynchron ermittelte Werte, gedacht als Eigenschaft eines Actors. Gleichzeitige Anfragen
/// desselben Schlüssels teilen sich einen laufenden `Task`; erst das fertige Ergebnis bestimmt über `lifetime`, wie
/// lange es gilt.
struct ExpiringTaskCache<Key: Hashable, Value: Sendable> {
    private struct Entry {
        let task: Task<Value, Never>
        /// `nil`, solange der Task läuft.
        var expires: Date?
    }

    private let lifetime: @Sendable (Value) -> TimeInterval
    private var entries: [Key: Entry] = [:]

    /// - Parameter lifetime: Gültigkeitsdauer (Sekunden) eines fertigen Ergebnisses.
    init(lifetime: @escaping @Sendable (Value) -> TimeInterval) {
        self.lifetime = lifetime
    }

    /// Laufender oder noch gültiger Task zu `key`, sonst ein neuer aus `compute`. Der Aufrufer wartet auf
    /// `task.value` und meldet das Ergebnis danach über `finish(_:task:value:now:)`.
    mutating func task(
        for key: Key, now: Date, compute: @escaping @Sendable () async -> Value
    ) -> Task<Value, Never> {
        if let entry = entries[key], entry.expires.map({ $0 > now }) ?? true { return entry.task }
        let task = Task { await compute() }
        entries[key] = Entry(task: task, expires: nil)
        return task
    }

    /// Setzt die Ablaufzeit beim ersten Abschluss von `task`, sofern er noch der aktuelle Eintrag zu `key` ist.
    /// Spätere Meldungen (Cache-Treffer) verlängern die Gültigkeit nicht.
    mutating func finish(_ key: Key, task: Task<Value, Never>, value: Value, now: Date) {
        guard let entry = entries[key], entry.task == task, entry.expires == nil else { return }
        entries[key]?.expires = now.addingTimeInterval(lifetime(value))
    }
}
