import Foundation

/// Gemeinsamer Arbeitsstapel einer festen Zahl Leser-Threads (zuletzt hineingelegt, zuerst gelesen: Tiefensuche hält
/// den Stapel klein). `next()` wartet, solange der Stapel leer ist, ein anderer Leser aber noch Arbeit nachlegen kann.
/// Sind alle fertig oder ist der Stapel gestoppt, liefert es `nil`.
///
/// `@unchecked Sendable`: Alle veränderlichen Felder werden nur unter `condition` gelesen und geschrieben.
final class OccupancyWorkStack<Item: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [Item]
    private var busy = 0
    private var isStopped = false

    init(_ items: [Item]) {
        self.items = items
    }

    /// Nächste Arbeit; der Aufrufer meldet sie danach mit `complete(adding:)` fertig.
    func next() -> Item? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty, busy > 0, !isStopped { condition.wait() }
        guard !isStopped, let item = items.popLast() else { return nil }
        busy += 1
        return item
    }

    /// Meldet die mit `next()` geholte Arbeit fertig und legt die daraus entstandene nach (die erste obenauf).
    func complete(adding more: [Item]) {
        condition.lock()
        defer { condition.unlock() }
        busy -= 1
        items.append(contentsOf: more.reversed())
        condition.broadcast()
    }

    /// Keine weitere Arbeit ausgeben; wartende Leser kehren mit `nil` zurück.
    func stop() {
        condition.lock()
        defer { condition.unlock() }
        isStopped = true
        items.removeAll()
        condition.broadcast()
    }
}
