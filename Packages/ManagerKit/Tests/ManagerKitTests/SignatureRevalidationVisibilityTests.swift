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

/// #662: Die verteilte Komplettprüfung läuft bevorzugt, solange kein Fenster und kein Popover Livewerte misst, und in
/// Blöcken kleiner Rechenzeit. Sichtbare Livewerte schieben sie auf, solange die Frist es erlaubt; die Zusage aus #649
/// bleibt hart (jeder Baum spätestens `maximumAge` nach seiner letzten Komplettprüfung erneut geprüft). Echte Engine,
/// virtuelle Zeit (`ScheduleHarness`).
@Suite(.timeLimit(.minutes(1)))
struct SignatureRevalidationVisibilityTests {
    private func apps(_ count: Int, in directory: URL) throws -> [URL] {
        try (0..<count).map { try Codesign.bundle(in: directory, named: "App\($0)", adHoc: true, resources: ["r.txt": "x"]) }
    }

    /// Prüfzeitpunkte je App seit `launch` (Start eingeschlossen) halten die Zusage ein, auch bis `end`.
    private func expectDeadlineKept(_ checks: [Date], launch: Date, end: Date, schedule: SignatureRevalidationSchedule,
                                    _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let all = [launch] + checks.filter { $0 > launch }
        let gaps = zip(all, all.dropFirst()).map { $1.timeIntervalSince($0) }
        #expect(gaps.allSatisfy { $0 <= schedule.maximumAge }, "\(name): \(gaps)", sourceLocation: sourceLocation)
        #expect(end.timeIntervalSince(all.last ?? launch) <= schedule.maximumAge, "\(name)", sourceLocation: sourceLocation)
    }

    /// Ein Fenster bleibt zwei Stunden sichtbar: Die Prüfung wartet jeweils bis zur Frist, läuft dann trotzdem (kein
    /// Aushungern) – selten, mehrere Bäume je Durchgang – und hält die Zusage.
    @Test func permanentlyVisibleWindowDefersToTheDeadlineAndKeepsItForTwoHours() async throws {
        try await ScratchDirectory.with(prefix: "visible-2h") { directory in
            let apps = try apps(4, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let launch = harness.elapsed
            let afterLaunch = harness.trees.count
            await harness.setLiveViews(visible: true)

            let end = launch.addingTimeInterval(2 * 3_600)
            #expect(await harness.runSchedule(until: end))
            let scheduled = Array(harness.trees.reads.dropFirst(afterLaunch))
            let first = try #require(scheduled.first)
            // Spätester Beginn: Frist abzüglich der geschätzten Arbeit der drei früher fälligen, gleich alten Bäume.
            let latest = harness.schedule.deadlineAge - Double(apps.count - 1) * harness.schedule.defaultTreeWork
            #expect(first.date >= launch.addingTimeInterval(latest - 0.001),
                    "aufgeschoben bis zum spätesten Beginn statt nach \(harness.schedule.gap(forTargetCount: apps.count)) s")
            #expect(scheduled.allSatisfy { $0.qos == QOS_CLASS_BACKGROUND })
            for app in apps {
                expectDeadlineKept(harness.trees.dates(of: app.path), launch: launch, end: end,
                                   schedule: harness.schedule, app.lastPathComponent)
            }
            let steps = Set(scheduled.map(\.date)).sorted()
            #expect(zip(steps, steps.dropFirst()).allSatisfy {
                $1.timeIntervalSince($0) >= harness.schedule.forcedHorizon - 0.001
            }, "wenige Durchgänge mit mehreren Bäumen: \(steps.map { $0.timeIntervalSince(launch) })")
            await harness.engine.stop()
        }
    }

    /// Sichtbar und verdeckt im Wechsel: Während sichtbarer Livewerte beginnt kein Durchgang vor der Frist; nach dem
    /// Verdecken folgt der nächste erst nach der Ruhezeit. Die Zusage gilt über den ganzen Wechsel.
    @Test func blocksMoveOutOfVisibleTimeAndFollowAfterTheSettlePeriod() async throws {
        try await ScratchDirectory.with(prefix: "visible-switch") { directory in
            let apps = try apps(4, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            let schedule = harness.schedule
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let launch = harness.elapsed
            #expect(await harness.runScheduleStep() == schedule.gap(forTargetCount: apps.count), "verdeckt im Takt")

            var visibleSpans: [(Date, Date)] = []
            var hiddenSince: [Date] = []
            for _ in 0..<6 {
                let shown = harness.elapsed
                await harness.setLiveViews(visible: true)
                #expect(await harness.runSchedule(until: shown.addingTimeInterval(400)))
                let hidden = harness.elapsed
                visibleSpans.append((shown, hidden))
                await harness.setLiveViews(visible: false)
                hiddenSince.append(hidden)
                #expect(await harness.runSchedule(until: hidden.addingTimeInterval(200)))
            }
            let end = harness.elapsed
            let reads = harness.trees.reads.filter { $0.date > launch }
            for (shown, hidden) in visibleSpans {
                for read in reads where read.date > shown && read.date < hidden {
                    let completed = harness.trees.dates(of: read.path).filter { $0 < read.date }.max() ?? launch
                    #expect(read.date.timeIntervalSince(completed) >= schedule.deadlineAge - schedule.forcedHorizon - 0.001,
                            "sichtbar nur, was die Frist verlangt")
                }
            }
            for hidden in hiddenSince {
                let early = reads.filter { $0.date > hidden && $0.date < hidden.addingTimeInterval(schedule.settle) }
                for read in early {
                    let completed = harness.trees.dates(of: read.path).filter { $0 < read.date }.max() ?? launch
                    #expect(read.date.timeIntervalSince(completed) >= schedule.deadlineAge - schedule.forcedHorizon - 0.001,
                            "in der Ruhezeit nur, was die Frist verlangt")
                }
            }
            #expect(reads.contains { read in hiddenSince.contains { read.date >= $0.addingTimeInterval(schedule.settle) } },
                    "verdeckt läuft die Prüfung wieder")
            for app in apps {
                expectDeadlineKept(harness.trees.dates(of: app.path), launch: launch, end: end, schedule: schedule,
                                   app.lastPathComponent)
            }
            await harness.engine.stop()
        }
    }

    /// Ruhezustand bei sichtbarem Fenster: Danach sind alle Bäume überfällig und offen; ein erzwungener Durchgang holt
    /// jeden genau einmal nach, Block für Block (je Baum ein volles Budget).
    @Test func overdueTreesAreCaughtUpInOneForcedPassWhileVisible() async throws {
        try await ScratchDirectory.with(prefix: "visible-sleep") { directory in
            let apps = try apps(3, in: directory)
            let harness = try ScheduleHarness(apps: apps, schedule: SignatureRevalidationSchedule(),
                                              walkCost: { _ in .milliseconds(250) })
            let walks = try #require(harness.walks)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            await harness.setLiveViews(visible: true)

            await harness.runScheduleStep(oversleep: 3 * 3_600)
            let wake = harness.elapsed
            let open = try #require(await states.next { $0.pendingSignatureChecks > 0 })
            #expect(open.pendingSignatureChecks >= apps.count - 1, "überfällige Bäume zählen als offen")
            while apps.contains(where: { walks.walks(of: $0.path).isEmpty }) {
                let waited = try #require(await harness.runScheduleStep())
                #expect(waited <= harness.schedule.blockPause + 0.001, "zügig nachgeholt, in Blöcken")
            }
            #expect(apps.allSatisfy { walks.walks(of: $0.path).count == 1 }, "jeder genau einmal")
            #expect(harness.elapsed.timeIntervalSince(wake) <= Double(apps.count) * harness.schedule.blockPause)
            _ = try #require(await states.next { $0.pendingSignatureChecks == 0 })
            await harness.engine.stop()
        }
    }

    /// Uhr vor und zurück bei sichtbarem Fenster: Fristen laufen auf der monotonen Uhr, die Zusage hält.
    @Test func wallClockJumpsWhileVisibleDoNotMoveTheDeadline() async throws {
        try await ScratchDirectory.with(prefix: "visible-clock") { directory in
            let apps = try apps(3, in: directory)
            let harness = try ScheduleHarness(apps: apps)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let launch = harness.elapsed
            await harness.setLiveViews(visible: true)

            #expect(await harness.runSchedule(until: launch.addingTimeInterval(800)))
            harness.dates.advance(by: -600)
            #expect(await harness.runSchedule(until: launch.addingTimeInterval(1_700)))
            harness.dates.advance(by: 7_200)
            let end = launch.addingTimeInterval(3 * harness.schedule.maximumAge)
            #expect(await harness.runSchedule(until: end))
            for app in apps {
                expectDeadlineKept(harness.trees.dates(of: app.path), launch: launch, end: end,
                                   schedule: harness.schedule, app.lastPathComponent)
            }
            await harness.engine.stop()
        }
    }

    // MARK: Blöcke

    /// Kosten der Bäume: `Big.app` braucht 0,6 s Rechenzeit (drei Blöcke), die übrigen je 0,05 s.
    private static let walkCost: @Sendable (String) -> Duration = {
        $0.hasSuffix("/Big.app") ? .milliseconds(600) : .milliseconds(50)
    }

    private func blockApps(in directory: URL) throws -> (apps: [URL], big: URL) {
        let big = try Codesign.bundle(in: directory, named: "Big", adHoc: true, resources: ["r.txt": "x"])
        return (try apps(3, in: directory) + [big], big)
    }

    /// Blöcke höchstens `blockBudget` Rechenzeit, dazwischen `blockPause`; ein großer Baum geht über mehrere Blöcke und
    /// gilt erst danach als geprüft. Die Zusage hält.
    @Test func largeTreeIsCheckedInSmallBlocksAndKeepsTheDeadline() async throws {
        try await ScratchDirectory.with(prefix: "blocks-engine") { directory in
            let (apps, big) = try blockApps(in: directory)
            let harness = try ScheduleHarness(apps: apps, schedule: SignatureRevalidationSchedule(), walkCost: Self.walkCost)
            let walks = try #require(harness.walks)
            let schedule = harness.schedule
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let launch = harness.elapsed
            let end = launch.addingTimeInterval(2 * 3_600)
            #expect(await harness.runSchedule(until: end))

            let budget = Duration.seconds(schedule.blockBudget)
            let advances = walks.advances
            #expect(advances.allSatisfy { ($0.budget ?? .zero) <= budget && $0.cpuTime <= budget })
            #expect(advances.allSatisfy { $0.qos == QOS_CLASS_BACKGROUND })
            let blocks = Dictionary(grouping: advances, by: \.date).mapValues { $0.reduce(Duration.zero) { $0 + $1.cpuTime } }
            #expect(blocks.values.allSatisfy { $0 <= budget }, "höchstens ein Budget am Stück: \(blocks.values.max() ?? .zero)")
            let bigWalks = Dictionary(grouping: advances.filter { $0.path == big.path }, by: \.walk)
            #expect(bigWalks.count >= 8)
            for (_, chunks) in bigWalks where chunks.last?.finished == true {
                #expect((3...4).contains(chunks.count), "über mehrere Blöcke")
                #expect(chunks.reduce(Duration.zero) { $0 + $1.cpuTime } == .milliseconds(600))
                let dates = chunks.map(\.date)
                #expect(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= schedule.blockPause - 0.001 })
            }
            for app in apps {
                expectDeadlineKept(walks.walks(of: app.path), launch: launch, end: end, schedule: schedule,
                                   app.lastPathComponent)
            }
            await harness.engine.stop()
        }
    }

    /// Ändert sich der große Baum zwischen zwei Blöcken, gilt er nicht als geprüft: Die Tiefenprüfung prüft ihn neu,
    /// und seine nächste Komplettprüfung beginnt einen neuen Durchlauf.
    @Test func changeBetweenTwoBlocksDiscardsTheHalfCheckedTree() async throws {
        try await ScratchDirectory.with(prefix: "blocks-change") { directory in
            let (apps, big) = try blockApps(in: directory)
            // Die Tiefenprüfung hält an, bis der Test sie freigibt: Der offene Baum bleibt sichtbar.
            let validator = ScriptedSignatureValidator(holding: true)
            apps.forEach { _ in validator.release() }
            let harness = try ScheduleHarness(apps: apps, validator: validator, schedule: SignatureRevalidationSchedule(),
                                              walkCost: Self.walkCost)
            let walks = try #require(harness.walks)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let launchChecks = validator.calls.filter { $0 == big.path }.count

            try await runUntilHalfChecked(big, walks: walks, harness: harness)
            try Data("<plist/>".utf8).write(to: big.appending(path: "Contents/Info.plist"))
            await harness.runScheduleStep()
            _ = try #require(await states.next { $0.pendingSignatureChecks > 0 }, "nicht als geprüft")
            validator.release()
            _ = try #require(await states.next { $0.pendingSignatureChecks == 0 })
            #expect(validator.calls.filter { $0 == big.path }.count == launchChecks + 1, "Tiefenprüfung des veränderten Baums")
            let halfChecked = try #require(walks.advances.last { $0.path == big.path })
            #expect(!halfChecked.finished, "der halb geprüfte Durchlauf wurde nicht fortgesetzt")

            let walksBefore = walks.walks(of: big.path).count
            #expect(await harness.runSchedule(until: harness.elapsed.addingTimeInterval(harness.schedule.maximumAge)))
            #expect(walks.walks(of: big.path).count > walksBefore, "beginnt neu")
            await harness.engine.stop()
        }
    }

    /// Wird während eines großen Baums ein Fenster sichtbar, prüft der Durchgang diesen Baum zu Ende und beginnt keinen
    /// weiteren; nach dem Verdecken und der Ruhezeit nimmt der Plan die Prüfung wieder auf.
    @Test func visibleWindowLetsTheStartedTreeFinishAndResumesLater() async throws {
        try await ScratchDirectory.with(prefix: "blocks-visible") { directory in
            let (apps, big) = try blockApps(in: directory)
            let harness = try ScheduleHarness(apps: apps, schedule: SignatureRevalidationSchedule(), walkCost: Self.walkCost)
            let walks = try #require(harness.walks)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))

            try await runUntilHalfChecked(big, walks: walks, harness: harness)
            let walk = try #require(walks.advances.last).walk
            // Der Plan pausiert zwischen zwei Blöcken (kein Neuplanen): Die Sichtbarkeit gilt ab dem nächsten Baum.
            harness.engine.setLiveViewsVisible(true)
            while walks.advances.last { $0.walk == walk }?.finished != true {
                try #require(await harness.runScheduleStep() != nil)
            }
            #expect(!walks.advances.contains { $0.walk > walk }, "kein weiterer Baum, solange sichtbar")

            await harness.setLiveViews(visible: false)
            let hidden = harness.elapsed
            #expect(await harness.runSchedule(until: hidden.addingTimeInterval(harness.schedule.period)))
            let resumed = try #require(walks.advances.first { $0.walk > walk }, "wieder aufgenommen")
            #expect(resumed.date >= hidden.addingTimeInterval(harness.schedule.settle - 0.001))
            #expect(walks.advances.filter { $0.walk == walk }.count == 3, "ein Durchlauf, fortgesetzt")
            await harness.engine.stop()
        }
    }

    /// `stop()` in der Pause zwischen zwei Blöcken: kein weiterer Block, kein Zeitgeber mehr.
    @Test func stopBetweenTwoBlocksEndsThePlan() async throws {
        try await ScratchDirectory.with(prefix: "blocks-stop") { directory in
            let (apps, big) = try blockApps(in: directory)
            let harness = try ScheduleHarness(apps: apps, schedule: SignatureRevalidationSchedule(), walkCost: Self.walkCost)
            let walks = try #require(harness.walks)
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))

            try await runUntilHalfChecked(big, walks: walks, harness: harness)
            await harness.engine.stop()
            let advances = walks.advances.count
            #expect(harness.clock.advance(by: .seconds(3_600)) == 0, "kein Plan mehr nach stop()")
            #expect(walks.advances.count == advances)
        }
    }

    /// Führt Planschritte aus, bis `tree` halb geprüft ist (der Plan pausiert zwischen zwei Blöcken).
    private func runUntilHalfChecked(_ tree: URL, walks: ScriptedTreeWalks, harness: ScheduleHarness) async throws {
        for _ in 0..<10_000 {
            if let last = walks.advances.last, last.path == tree.path, !last.finished { return }
            try #require(await harness.runScheduleStep() != nil)
        }
        Issue.record("\(tree.lastPathComponent) wurde nie in Blöcken geprüft")
    }

    /// Codex-Review zu PR 665: Viele bzw. große, gleich alte Bäume (nach dem Start) bei dauerhaft sichtbarem Fenster,
    /// gedrosselt (Wanduhr das Doppelte der Rechenzeit). Jeder Baum ist spätestens `maximumAge` nach Beginn seiner letzten
    /// Komplettprüfung erneut fertig geprüft – samt aller Blöcke und Pausen, auch im ersten Durchgang ohne gemessene Arbeit.
    @Test(arguments: zip([10, 24], [1_000, 250]))
    func equallyOldTreesFinishBeforeTheirDeadlineWhileVisible(count: Int, milliseconds: Int) async throws {
        try await ScratchDirectory.with(prefix: "visible-cost") { directory in
            let apps = try (0..<count).map { try Codesign.bundle(in: directory, named: "T\($0)", adHoc: false) }
            let harness = try ScheduleHarness(apps: apps, schedule: SignatureRevalidationSchedule(),
                                              walkCost: { _ in .milliseconds(milliseconds) }, wallPerCPU: 2)
            let walks = try #require(harness.walks)
            let schedule = harness.schedule
            var states = await harness.engine.states().makeAsyncIterator()
            await harness.engine.start()
            _ = try #require(await states.next(where: settled(at: harness.now)))
            let launch = harness.elapsed
            await harness.setLiveViews(visible: true)

            let end = launch.addingTimeInterval(2 * 3_600)
            #expect(await harness.runSchedule(until: end))
            let started = walks.walks
            let finished = Dictionary(grouping: walks.advances.filter(\.finished), by: \.walk).mapValues { $0[0].date }
            for app in apps {
                let checks = started.indices.filter { started[$0].path == app.path }
                    .compactMap { index in finished[index].map { (start: started[index].date, finish: $0) } }
                #expect(checks.count >= 7, "\(app.lastPathComponent): \(checks.count) Prüfungen")
                let previousStarts = [launch] + checks.map(\.start)
                for (previous, check) in zip(previousStarts, checks) {
                    #expect(check.finish.timeIntervalSince(previous) <= schedule.maximumAge,
                            "\(app.lastPathComponent): fertig nach \(check.finish.timeIntervalSince(previous)) s")
                }
            }
            #expect(walks.advances.allSatisfy { $0.cpuTime <= .seconds(schedule.blockBudget) })
            // Ab der zweiten Stunde ist die Arbeit je Baum gemessen: Der Plan beginnt früh genug, die Blöcke behalten ihre
            // Pausen (Rechenzeit am Stück höchstens ein Block; Abschnittsbeginn = Ende minus doppelte Rechenzeit).
            let later = walks.advances.filter { $0.date > launch.addingTimeInterval(3_600) }
            var chain = later.first?.cpuTime ?? .zero
            var longest = chain
            for (previous, next) in zip(later, later.dropFirst()) {
                let gap = next.date.timeIntervalSince(previous.date) - 2 * Self.seconds(next.cpuTime)
                chain = gap < schedule.blockPause / 2 ? chain + next.cpuTime : next.cpuTime
                longest = max(longest, chain)
            }
            #expect(longest <= .seconds(schedule.blockBudget) + .milliseconds(1), "am Stück: \(longest)")
            await harness.engine.stop()
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Codex-Review zu PR 665: Der Block beginnt vor seinem ersten Abschnitt; die Wanduhr im Debug-Eintrag enthält dessen
    /// Laufzeit, sonst sähe `disturbances.py` einen Block aus einem Abschnitt als Zeitpunkt statt als Zeitraum. Ohne
    /// Arbeit kein Eintrag.
    @Test func blockWallIncludesItsFirstChunk() {
        var block = MonitoringEngine.SignatureBlock()
        #expect(block.message(endingAt: .now) == nil, "ohne Arbeit kein Eintrag")
        let start = ContinuousClock.now
        block.begin(at: start)
        block.add(.milliseconds(250), exhausted: true, budget: .milliseconds(250))
        block.begin(at: start + .milliseconds(300))
        #expect(block.message(endingAt: start + .milliseconds(400)) == "Signaturprüfung: Block cpu=0.250 wall=0.400")
    }

    /// Format der Debug-Einträge, das `scripts/performance/disturbances.py` liest.
    @Test func signatureWorkIsLoggedInTheFormatTheAcceptanceReads() {
        #expect(MonitoringEngine.signatureWorkMessage(.block(cpu: .milliseconds(213)), wall: .milliseconds(402))
            == "Signaturprüfung: Block cpu=0.213 wall=0.402")
        #expect(MonitoringEngine.signatureWorkMessage(.deepCheck, wall: .seconds(1.25))
            == "Signaturprüfung: Tiefenprüfung wall=1.250")
    }
}
