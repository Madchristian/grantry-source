import Testing
import Foundation
import Synchronization
import TestSupport
@testable import GrantryShared

@Suite(.timeLimit(.minutes(1))) struct IdleMonitorTests {
    @Test func reportsIdleAfterTimeoutWithoutActivity() async {
        let probe = IdleProbe()
        let monitor = probe.makeMonitor()
        monitor.start()
        await probe.clock.waitForSleeper(until: .at(.seconds(300)))
        probe.clock.advance(by: .seconds(299))
        probe.clock.advance(by: .seconds(1))
        #expect(await probe.idleTime() == .seconds(300))
    }

    @Test func activityRestartsTimeout() async {
        let probe = IdleProbe()
        let monitor = probe.makeMonitor()
        monitor.start()
        await probe.clock.waitForSleeper(until: .at(.seconds(300)))
        probe.clock.advance(by: .seconds(200))
        monitor.beginActivity().end()
        await probe.clock.waitForSleeper(until: .at(.seconds(500)))
        probe.clock.advance(by: .seconds(100))
        probe.clock.advance(by: .seconds(200))
        #expect(await probe.idleTime() == .seconds(500))
    }

    @Test func openActivityPreventsIdle() async {
        let probe = IdleProbe()
        let monitor = probe.makeMonitor()
        monitor.start()
        await probe.clock.waitForSleeper(until: .at(.seconds(300)))
        let activity = monitor.beginActivity()
        probe.clock.advance(by: .seconds(1000))
        #expect(monitor.activeCount == 1)
        activity.end()
        await probe.expire(at: .seconds(1300))
        #expect(await probe.idleTime() == .seconds(1300))
    }

    @Test func endingAnActivityTwiceCountsOnce() {
        let monitor = IdleProbe().makeMonitor()
        let first = monitor.beginActivity()
        _ = monitor.beginActivity()
        first.end()
        first.end()
        #expect(monitor.activeCount == 1)
    }

    @Test func customTimeoutIsUsed() async {
        let probe = IdleProbe()
        let monitor = probe.makeMonitor(timeout: .seconds(5))
        monitor.start()
        await probe.expire(at: .seconds(5))
        #expect(await probe.idleTime() == .seconds(5))
        withExtendedLifetime(monitor) {}
    }

    @Test func reportsIdleAgainAfterFurtherActivity() async {
        let probe = IdleProbe()
        let monitor = probe.makeMonitor(timeout: .seconds(10))
        monitor.start()
        await probe.expire(at: .seconds(10))
        #expect(await probe.idleTime() == .seconds(10))
        monitor.beginActivity().end()
        await probe.expire(at: .seconds(20))
        #expect(await probe.idleTime() == .seconds(20))
    }

    /// `onIdle` läuft unter der Sperre: Eine gleichzeitig beginnende Aktivität wartet, bis `onIdle` zurückkehrt.
    /// Beendet `onIdle` den Prozess, kann so keine Verbindung mehr zwischen Prüfung und `exit` angenommen werden.
    @Test func activityBeginningDuringOnIdleWaitsUntilOnIdleReturned() async {
        let clock = TestClock()
        let log = EventLog()
        let finished = AsyncStream.makeStream(of: Void.self)
        let monitor = IdleMonitor(timeout: .seconds(1), clock: clock) {
            log.append("idle-start")
            let competitor = Thread {
                _ = log.monitor?.beginActivity()
                log.append("begin-returned")
                finished.continuation.yield()
            }
            competitor.start()
            Thread.sleep(forTimeInterval: 0.1)
            log.append("idle-end")
        }
        log.monitor = monitor
        monitor.start()
        await clock.waitForSleeper(until: .at(.seconds(1)))
        clock.advance(by: .seconds(1))
        _ = await finished.stream.first { _ in true }
        #expect(log.events == ["idle-start", "idle-end", "begin-returned"])
    }
}

/// Threadsicheres Ereignisprotokoll samt Verweis auf den geprüften Monitor.
private final class EventLog: Sendable {
    private let state = Mutex<(events: [String], monitor: IdleMonitor?)>(([], nil))

    var events: [String] { state.withLock { $0.events } }
    var monitor: IdleMonitor? {
        get { state.withLock { $0.monitor } }
        set { state.withLock { $0.monitor = newValue } }
    }

    func append(_ event: String) { state.withLock { $0.events.append(event) } }
}
