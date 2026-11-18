import Foundation
import Testing
import TestSupport
@testable import ManagerKit

private extension AsyncStream.Iterator where Element == MonitoringState {
    mutating func next(where predicate: (MonitoringState) -> Bool) async -> MonitoringState? {
        while let state = await next() {
            if predicate(state) { return state }
        }
        return nil
    }
}

// MARK: - Tests

/// #649, Variante B: Intervall- und Dateiänderungs-Vollscans prüfen die Bundle-Stempel; die Komplettprüfung der Code-
/// Bäume verteilt ein Plan der Engine (`SignatureRevalidationSchedule`). Start und manueller Scan prüfen alles am Stück.
@Suite(.timeLimit(.minutes(1)))
struct SignatureRevalidationEngineTests {
    private func apps(_ count: Int, in directory: URL) throws -> [URL] {
        try (0..<count).map { try Codesign.bundle(in: directory, named: "App\($0)", adHoc: true, resources: ["r.txt": "x"]) }
    }

    @Test func intervalScanChecksOnlyBundleStampsAndManualScanChecksEveryTree() async throws {
        try await ScratchDirectory.with(prefix: "schedule-interval") { directory in
            let apps = try apps(3, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let afterLaunch = harness.trees.count
            #expect(apps.allSatisfy { harness.reads(of: $0) >= 1 }, "der Start prüft jeden Baum komplett")

            harness.advance(seconds: 1)
            harness.triggers.send(.interval)
            _ = try #require(await states.next(where: settled(at: harness.now)))
            #expect(harness.trees.count == afterLaunch, "Intervall-Vollscan: nur Bundle-Stempel")

            harness.advance(seconds: 1)
            harness.triggers.send(.manual)
            _ = try #require(await states.next(where: settled(at: harness.now)))
            #expect(apps.allSatisfy { harness.reads(of: $0, since: afterLaunch) == 1 }, "manuell: jeder Baum am Stück")
            await harness.engine.stop()
        }
    }

    /// Kern der Zusage: Über zwei Stunden ohne weitere Scans ist jeder Baum spätestens `maximumAge` nach seiner
    /// letzten Komplettprüfung erneut komplett geprüft – verteilt (nie zwei Bäume im selben Schritt), mit
    /// Hintergrund-Priorität und ohne Mehrlast gegenüber einem Durchlauf je Periode.
    @Test func everyTreeIsCompletelyCheckedWithinTheMaximumAge() async throws {
        try await ScratchDirectory.with(prefix: "schedule-age") { directory in
            let apps = try apps(4, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let launch = harness.elapsed
            let afterLaunch = harness.trees.count

            let end = launch.addingTimeInterval(2 * 3_600)
            while harness.elapsed < end {
                let waited = try #require(await harness.runScheduleStep())
                #expect(waited >= harness.schedule.gap(forTargetCount: apps.count) - 0.001, "ein Baum je Abstand")
            }
            _ = await harness.clock.nextSleeperDeadline()

            let scheduled = harness.trees.reads.dropFirst(afterLaunch)
            #expect(scheduled.allSatisfy { $0.qos == QOS_CLASS_BACKGROUND })
            for app in apps {
                let checks = [launch] + harness.trees.dates(of: app.path).filter { $0 > launch }
                let gaps = zip(checks, checks.dropFirst()).map { $1.timeIntervalSince($0) }
                #expect(gaps.allSatisfy { $0 <= harness.schedule.maximumAge }, "\(app.lastPathComponent): \(gaps)")
                #expect(end.timeIntervalSince(checks.last ?? launch) <= harness.schedule.maximumAge)
            }
            let periods = (end.timeIntervalSince(launch) / harness.schedule.period).rounded(.up)
            #expect(scheduled.count <= apps.count * Int(periods), "keine Mehrlast")
            await harness.engine.stop()
        }
    }

    /// Mit Zeitbudget prüft ein Schritt mehrere Bäume am Stück (weniger Einzelstarts, weniger CPU-Zeit) und rückt den
    /// nächsten Schritt um ebenso viele Abstände weiter: je Periode bleibt es bei einer Prüfung je Baum.
    @Test func smallTreesShareOneBlockAndThePaceFollows() async throws {
        try await ScratchDirectory.with(prefix: "schedule-block") { directory in
            let apps = try apps(4, in: directory)
            let harness = try ScheduleHarness(apps: apps, schedule: SignatureRevalidationSchedule(stepBudget: 60))
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let afterLaunch = harness.trees.count

            let first = try #require(await harness.runScheduleStep())
            let second = try #require(await harness.runScheduleStep())
            _ = await harness.clock.nextSleeperDeadline()
            #expect(first == harness.schedule.gap(forTargetCount: apps.count))
            #expect(second == harness.schedule.period, "vier Bäume im Block: vier Abstände bis zum nächsten")
            #expect(harness.trees.count == afterLaunch + 2 * apps.count)
            #expect(apps.allSatisfy { harness.reads(of: $0, since: afterLaunch) == 2 })
            await harness.engine.stop()
        }
    }

    /// Ruhezustand: Der Zeitgeber feuert erst Stunden später. Danach gelten alle Bäume als offen (nie als aktuell
    /// geprüft), und der Plan holt sie gleich nach – ältester zuerst, mit kurzer Pause, ohne einen auszulassen.
    @Test func overdueTreesAreShownAsOpenAndCaughtUpAfterWaking() async throws {
        try await ScratchDirectory.with(prefix: "schedule-wake") { directory in
            let apps = try apps(3, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            await harness.runScheduleStep()
            let beforeSleep = harness.trees.count

            await harness.runScheduleStep(oversleep: 3 * 3_600)
            let wake = harness.elapsed
            let open = try #require(await states.next { $0.pendingSignatureChecks > 0 })
            #expect(open.pendingSignatureChecks >= apps.count - 1, "überfällige Bäume zählen als offen")
            while harness.reads(of: apps[0], since: beforeSleep) == 0 || harness.reads(of: apps[1], since: beforeSleep) == 0
                    || harness.reads(of: apps[2], since: beforeSleep) == 0 {
                let waited = try #require(await harness.runScheduleStep())
                #expect(waited <= harness.schedule.catchUpPause + 0.001, "zügig nachgeholt")
            }
            #expect(harness.elapsed.timeIntervalSince(wake) <= Double(apps.count) * harness.schedule.catchUpPause)
            #expect(apps.allSatisfy { harness.reads(of: $0, since: beforeSleep) == 1 }, "jeder genau einmal")
            _ = try #require(await states.next { $0.pendingSignatureChecks == 0 })
            await harness.engine.stop()
        }
    }

    /// Betrifft eine Dateiänderung erkennbar ein Signaturziel, prüft der Vollscan diesen Baum sofort komplett, die
    /// übrigen nur über ihre Stempel.
    @Test func fileChangeInsideATargetChecksThatTreeAtOnce() async throws {
        try await ScratchDirectory.with(prefix: "schedule-file") { directory in
            let apps = try apps(3, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let afterLaunch = harness.trees.count

            harness.advance(seconds: 1)
            harness.triggers.send(.fileChange(path: apps[1].appending(path: "Contents").path))
            _ = try #require(await states.next(where: settled(at: harness.now)))
            #expect(harness.reads(of: apps[1], since: afterLaunch) == 1)
            #expect(harness.trees.count == afterLaunch + 1)

            harness.advance(seconds: 1)
            harness.triggers.send(.fileChange(path: "/Library/LaunchAgents"))
            _ = try #require(await states.next(where: settled(at: harness.now)))
            #expect(harness.trees.count == afterLaunch + 1, "Änderung außerhalb der Ziele: nur Stempel")
            await harness.engine.stop()
        }
    }

    /// Ein manueller Scan, der während eines laufenden Scans mit einer späteren Dateiänderung zusammengefasst wird,
    /// prüft trotzdem jeden Baum komplett.
    @Test func manualScanMergedWithAFileChangeStillChecksEveryTree() async throws {
        try await ScratchDirectory.with(prefix: "schedule-merge") { directory in
            let apps = try apps(2, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            var sourceStarts = harness.source.starts.makeAsyncIterator()
            await harness.engine.start()
            _ = await sourceStarts.next()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let afterLaunch = harness.trees.count

            let gate = Gate()
            harness.source.hold(at: gate)
            harness.advance(seconds: 1)
            harness.triggers.send(.interval)
            _ = await sourceStarts.next()
            harness.triggers.send(.manual)
            harness.triggers.send(.fileChange(path: "/Library/LaunchAgents"))
            harness.advance(seconds: 1)
            harness.source.hold(at: nil)
            gate.open()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            #expect(apps.allSatisfy { harness.reads(of: $0, since: afterLaunch) == 1 })
            await harness.engine.stop()
        }
    }

    /// Neu hinzugekommene Ziele prüft schon der Scan komplett und danach der Plan; entfernte prüft er nicht mehr.
    @Test func addedAndRemovedTargetsFollowTheScans() async throws {
        try await ScratchDirectory.with(prefix: "schedule-targets") { directory in
            let apps = try apps(3, in: directory)
            let harness = try ScheduleHarness(apps: Array(apps.prefix(2)))
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))

            harness.advance(seconds: 1)
            harness.source.set(ScheduleHarness.contribution(Array(apps.suffix(2))))
            harness.triggers.send(.interval)
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let changed = harness.elapsed
            #expect(harness.reads(of: apps[2]) >= 1, "neues Ziel sofort komplett")
            let removedReads = harness.reads(of: apps[0])

            while harness.elapsed < changed.addingTimeInterval(3 * harness.schedule.maximumAge) {
                try #require(await harness.runScheduleStep() != nil)
            }
            #expect(harness.reads(of: apps[0]) == removedReads, "entferntes Ziel nicht mehr")
            for app in apps.suffix(2) {
                let checks = harness.trees.dates(of: app.path).filter { $0 >= changed.addingTimeInterval(-1) }
                let gaps = zip(checks, checks.dropFirst()).map { $1.timeIntervalSince($0) }
                #expect(checks.count >= 3)
                #expect(gaps.allSatisfy { $0 <= harness.schedule.maximumAge }, "\(app.lastPathComponent): \(gaps)")
            }
            await harness.engine.stop()
        }
    }

    /// Codex-Review zu PR 655: Die Wanduhr springt nach 800 s um 600 s zurück, die Prüfzeitpunkte liegen danach nicht in
    /// der Zukunft. Prüfalter und Fristen laufen auf der monotonen Uhr: Jeder Baum ist trotzdem spätestens 15 min nach
    /// seiner letzten Komplettprüfung erneut geprüft.
    @Test func wallClockSetBackPartlyDoesNotDelayTheNextCompleteCheck() async throws {
        try await ScratchDirectory.with(prefix: "schedule-clock-back") { directory in
            let apps = try apps(3, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let launch = harness.elapsed

            while harness.elapsed < launch.addingTimeInterval(2 * harness.schedule.gap(forTargetCount: apps.count)) {
                try #require(await harness.runScheduleStep() != nil)
            }
            harness.advance(seconds: launch.addingTimeInterval(800).timeIntervalSince(harness.elapsed))
            harness.dates.advance(by: -600)
            while harness.elapsed < launch.addingTimeInterval(2 * harness.schedule.maximumAge) {
                try #require(await harness.runScheduleStep() != nil)
            }
            for app in apps {
                let checks = [launch] + harness.trees.dates(of: app.path).filter { $0 > launch }
                let gaps = zip(checks, checks.dropFirst()).map { $1.timeIntervalSince($0) }
                #expect(gaps.allSatisfy { $0 <= harness.schedule.maximumAge }, "\(app.lastPathComponent): \(gaps)")
            }
            await harness.engine.stop()
        }
    }

    /// Springt die Wanduhr vor, gilt kein Baum als überfällig: keine offenen Prüfungen, kein Nachholen auf einen Schlag,
    /// der Plan behält seinen Abstand.
    @Test func wallClockSetForwardKeepsThePace() async throws {
        try await ScratchDirectory.with(prefix: "schedule-clock-forward") { directory in
            let apps = try apps(3, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let afterLaunch = harness.trees.count
            harness.dates.advance(by: 3_600)

            let gap = harness.schedule.gap(forTargetCount: apps.count)
            #expect(await harness.runScheduleStep() == gap)
            #expect(await harness.runScheduleStep() == gap)
            _ = await harness.clock.nextSleeperDeadline()
            #expect(harness.trees.count == afterLaunch + 2)
            var current = await harness.engine.states().makeAsyncIterator()
            #expect(await current.next()?.pendingSignatureChecks == 0, "nichts überfällig")
            await harness.engine.stop()
        }
    }

    /// Abbruch und Wiederaufnahme: Solange alle Ziele in der Tiefenprüfung stecken, schläft kein Plan; danach setzt er
    /// ein, ohne einen Baum auszulassen. Mit `stop()` endet er.
    @Test func scheduleResumesAfterPendingChecksAndEndsWithStop() async throws {
        try await ScratchDirectory.with(prefix: "schedule-resume") { directory in
            let apps = try apps(2, in: directory)
            let validator = ScriptedSignatureValidator(holding: true)
            let harness = try ScheduleHarness(apps: apps, validator: validator)
            var states = await harness.engine.states().makeAsyncIterator()
            var starts = validator.starts.makeAsyncIterator()
            await harness.engine.start()
            #expect(await starts.next() == apps[0].path)
            _ = try #require(await states.next { !$0.isScanning && $0.pendingSignatureChecks == apps.count })
            #expect(harness.clock.sleeperCount == 0, "kein Plan, solange alle Ziele in der Tiefenprüfung stecken")
            validator.release()
            validator.release()
            _ = try #require(await states.next { !$0.isScanning && $0.pendingSignatureChecks == 0 })
            let resumed = harness.elapsed

            while harness.elapsed < resumed.addingTimeInterval(2 * harness.schedule.maximumAge) {
                try #require(await harness.runScheduleStep() != nil)
            }
            for app in apps {
                let checks = harness.trees.dates(of: app.path).filter { $0 >= resumed }
                #expect(checks.count >= 2, "\(app.lastPathComponent)")
            }

            _ = await harness.clock.nextSleeperDeadline()
            await harness.engine.stop()
            let afterStop = harness.trees.count
            #expect(harness.clock.advance(by: .seconds(3_600)) == 0, "kein Plan mehr nach stop()")
            #expect(harness.trees.count == afterStop)
        }
    }
}
