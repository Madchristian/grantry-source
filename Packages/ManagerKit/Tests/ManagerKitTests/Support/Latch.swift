import Foundation

/// Hält Aufrufe an, bis `release()` kommt – ein hängender Aufruf, den der Test am Ende selbst löst.
final class Latch: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func release(_ count: Int = 1) { for _ in 0..<count { semaphore.signal() } }
}
