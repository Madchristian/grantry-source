import Foundation
import Synchronization

/// Von Hand vorgestellte Uhr für Tests mit Ablaufzeiten.
public final class ManualClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 0))

    public init() {}

    public var now: Date { date.withLock { $0 } }

    public func advance(by seconds: TimeInterval) { date.withLock { $0.addTimeInterval(seconds) } }
}
