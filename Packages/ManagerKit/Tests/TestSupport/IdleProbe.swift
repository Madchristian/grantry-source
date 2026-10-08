import GrantryShared

/// Erzeugt `IdleMonitor`s auf einer `TestClock` und zeichnet auf, zu welchem Zeitpunkt sie Leerlauf melden.
public final class IdleProbe: Sendable {
    public let clock = TestClock()
    private let stream: AsyncStream<Duration>
    private let continuation: AsyncStream<Duration>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream(of: Duration.self)
    }

    public func makeMonitor(timeout: Duration = IdleMonitor.defaultTimeout) -> IdleMonitor {
        IdleMonitor(timeout: timeout, clock: clock) { [clock, continuation] in
            continuation.yield(clock.now.offset)
        }
    }

    /// Zeitpunkt der nächsten Leerlauf-Meldung.
    public func idleTime() async -> Duration? {
        await stream.first { _ in true }
    }

    /// Wartet auf den Leerlauf-Timer mit Frist `deadline` und stellt die Uhr bis dorthin vor.
    public func expire(at deadline: Duration) async {
        await clock.waitForSleeper(until: .at(deadline))
        clock.advance(by: deadline - clock.now.offset)
    }
}
