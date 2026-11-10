import Darwin
import Foundation
import Testing
@testable import ManagerKit

/// Bewertung 2026.11.7-1188, Mangel 6: „Laufzeit“ zählt seit dem Start, auch über Ruhezustände hinweg – nicht nur die
/// Wachzeit (`ProcessInfo.systemUptime`).
@Suite struct SystemUptimeTests {
    @Test func countsFromBootTime() {
        let boot = timeval(tv_sec: 1_000_000, tv_usec: 500_000)
        let now = Date(timeIntervalSince1970: 1_000_000 + 11 * 86_400 + 0.5)
        #expect(SystemUptime.seconds(sinceBoot: boot, now: now) == 11 * 86_400)
    }

    @Test func clockBeforeBootGivesZero() {
        let boot = timeval(tv_sec: 2_000, tv_usec: 0)
        #expect(SystemUptime.seconds(sinceBoot: boot, now: Date(timeIntervalSince1970: 1_000)) == 0)
    }

    /// Ist `kern.boottime` nicht lesbar, gilt die Wachzeit; sonst zählt die Zeit seit dem Start, nicht die Wachzeit.
    @Test func unreadableBootTimeFallsBackToAwakeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000 + 3_600)
        #expect(SystemUptime.sinceBoot(now: now, boot: nil, awake: 42) == 42)
        #expect(SystemUptime.sinceBoot(now: now, boot: timeval(tv_sec: 1_000_000, tv_usec: 0), awake: 42) == 3_600)
    }
}

/// Vergleich mit den Uhrwerten dieses Macs – nur mit `MANAGERKIT_LIVE=1`: Auf einem Runner kann eine Uhrkorrektur nach dem
/// Start (Update, Neustart, Zeitabgleich) `kern.boottime` gegenüber der Wachzeit verschieben.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"))
struct SystemUptimeLiveTests {
    /// Seit dem Start vergeht mindestens so viel Zeit wie wach verbracht.
    @Test func thisMacIsUpAtLeastAsLongAsAwake() {
        let awake = ProcessInfo.processInfo.systemUptime
        #expect(SystemUptime.sinceBoot() >= awake - 1)
    }
}
