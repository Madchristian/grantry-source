import Foundation
import Testing
@testable import ManagerKit

/// Plan der verteilten Komplettprüfung (#649, Variante B): Zusage „jeder Baum spätestens `maximumAge` nach seiner
/// letzten Komplettprüfung erneut komplett geprüft“, gleichmäßig verteilt statt am Stück.
@Suite struct SignatureRevalidationScheduleTests {
    let schedule = SignatureRevalidationSchedule()
    let start = Date(timeIntervalSince1970: 1_000_000)

    /// Führt den Plan ohne Verzögerung aus: Jeder Schritt läuft genau zu seinem Zeitpunkt und prüft einen Block aus
    /// `blockSize(step)` Bäumen in Fristreihenfolge (wie die Engine bis zu ihrem Zeitbudget). Liefert je geprüftem Baum
    /// einen Eintrag.
    private func simulate(
        _ schedule: SignatureRevalidationSchedule, targets: [String], completedAt initial: [String: Date],
        from: Date, until end: Date, blockSize: (Int) -> Int = { _ in 1 }
    ) -> [SignatureRevalidationSchedule.Step] {
        var completedAt = initial
        var previous = from
        var previousBlock = 1
        var checks: [SignatureRevalidationSchedule.Step] = []
        var index = 0
        while let step = schedule.nextStep(targets: targets, completedAt: completedAt, attemptedAt: [:],
                                           previousStep: previous, previousBlockSize: previousBlock,
                                           now: max(previous, checks.last?.date ?? from)),
              step.date <= end {
            let block = schedule.dueOrder(targets, completedAt: completedAt, attemptedAt: [:], now: step.date)
                .prefix(max(1, blockSize(index)))
            #expect(block.first == step.path)
            for path in block {
                checks.append(.init(path: path, date: step.date))
                completedAt[path] = step.date
            }
            previous = step.date
            previousBlock = block.count
            index += 1
        }
        return checks
    }

    @Test func freshTreesAreSpreadEvenlyOverThePeriod() {
        let targets = ["a", "b", "c", "d"]
        let completed = Dictionary(uniqueKeysWithValues: targets.map { ($0, start) })
        let steps = simulate(schedule, targets: targets, completedAt: completed, from: start,
                             until: start.addingTimeInterval(2 * schedule.period))
        let gap = schedule.period / 4
        #expect(steps.prefix(5).map(\.path) == ["a", "b", "c", "d", "a"])
        #expect(steps.prefix(5).map { $0.date.timeIntervalSince(start) } == [1, 2, 3, 4, 5].map { $0 * gap },
                "ein Baum je Viertel der Periode statt alle am Stück")
    }

    /// Die Zusage gilt für jede Ausgangslage: nach dem Start (alle gleich alt), mit verstreuten Prüfzeiten und mit
    /// Bäumen, die noch nie geprüft wurden. Dabei prüft der Plan je Periode jeden Baum nur einmal (keine Mehrlast).
    /// Ein Block aus mehreren Bäumen rückt den nächsten Schritt um ebenso viele Abstände weiter: Je Periode bleibt es bei
    /// einer Prüfung je Baum, nur in weniger, größeren Blöcken.
    @Test func blockAdvancesThePaceByItsSize() {
        let targets = ["a", "b", "c", "d"]
        let completed = Dictionary(uniqueKeysWithValues: targets.map { ($0, start) })
        let step = schedule.nextStep(targets: targets, completedAt: completed, attemptedAt: [:], previousStep: start,
                                     previousBlockSize: 3, now: start)
        #expect(step?.date == start.addingTimeInterval(3 * schedule.gap(forTargetCount: 4)))
        let checks = simulate(schedule, targets: targets, completedAt: completed, from: start,
                              until: start.addingTimeInterval(2 * schedule.period), blockSize: { _ in 2 })
        #expect(checks.map(\.path) == ["a", "b", "c", "d", "a", "b", "c", "d"])
        #expect(Set(checks.map(\.date)).count == 4, "zwei Bäume je Block")
    }

    @Test func dueOrderPutsOverdueAndOldestFirst() {
        let now = start.addingTimeInterval(schedule.maximumAge)
        let completed = ["frisch": now, "alt": start, "mittel": start.addingTimeInterval(100)]
        #expect(schedule.dueOrder(["frisch", "mittel", "nie", "alt"], completedAt: completed, attemptedAt: [:], now: now)
            == ["nie", "alt", "mittel", "frisch"])
    }

    @Test(arguments: [0, 1, 2, 3])
    func everyTreeIsCheckedAgainWithinTheMaximumAge(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let targets = (0..<61).map { "/Applications/App\($0).app" }
        var completed: [String: Date] = [:]
        for target in targets where seed == 0 || Int.random(in: 0..<10, using: &generator) > 0 {
            let age = seed == 0 ? 0 : TimeInterval.random(in: 0...schedule.period, using: &generator)
            completed[target] = start.addingTimeInterval(-age)
        }
        let end = start.addingTimeInterval(3 * 3_600)
        // Blöcke wechselnder Größe wie unter dem Zeitbudget der Engine (Saat 0: Einzelschritte).
        let sizes = (0..<4_000).map { _ in seed == 0 ? 1 : Int.random(in: 1...12, using: &generator) }
        let steps = simulate(schedule, targets: targets, completedAt: completed, from: start, until: end,
                             blockSize: { sizes[$0 % sizes.count] })

        for target in targets {
            let checks = [completed[target]].compactMap(\.self) + steps.filter { $0.path == target }.map(\.date)
            let gaps = zip(checks, checks.dropFirst()).map { $1.timeIntervalSince($0) }
            #expect(gaps.allSatisfy { $0 <= schedule.maximumAge }, "\(target): \(gaps)")
            #expect(end.timeIntervalSince(checks.last ?? start) <= schedule.maximumAge, "\(target)")
        }
        let rounds = (end.timeIntervalSince(start) / schedule.period).rounded(.up)
        #expect(steps.count <= targets.count * (Int(rounds) + 1), "höchstens eine Prüfung je Baum und Periode")
    }

    /// Nach dem Ruhezustand sind alle Bäume überfällig: Der Plan holt sie gleich nach dem Aufwachen nach, ältester
    /// zuerst, mit kurzer Pause und ohne einen auszulassen.
    @Test func overdueTreesAreCaughtUpRightAfterWaking() {
        let targets = ["a", "b", "c"]
        var completed = ["a": start, "b": start.addingTimeInterval(-60), "c": start.addingTimeInterval(-30)]
        let wake = start.addingTimeInterval(3 * 3_600)
        var previous = start.addingTimeInterval(200)
        var order: [String] = []
        var now = wake
        for _ in targets {
            let step = try! #require(schedule.nextStep(targets: targets, completedAt: completed, attemptedAt: [:],
                                                       previousStep: previous, now: now))
            #expect(step.date <= max(now, previous.addingTimeInterval(schedule.catchUpPause)))
            now = max(now, step.date)
            order.append(step.path)
            completed[step.path] = now
            previous = now
        }
        #expect(order == ["b", "c", "a"])
        #expect(now.timeIntervalSince(wake) <= Double(targets.count) * schedule.catchUpPause)
    }

    @Test func treeWithoutCompleteCheckComesFirst() {
        let completed = ["a": start, "b": start]
        let step = schedule.nextStep(targets: ["a", "b", "neu"], completedAt: completed, attemptedAt: [:],
                                     previousStep: start, now: start)
        #expect(step == .init(path: "neu", date: start.addingTimeInterval(schedule.catchUpPause)))
    }

    /// Ein Baum ohne Bestätigung (etwa weil er sich während der Prüfung änderte) wird nicht in einer Schleife erneut
    /// angestoßen, sondern frühestens nach `retryPause`.
    @Test func unconfirmedTreeWaitsForTheRetryPause() {
        let attempted = ["neu": start.addingTimeInterval(-10)]
        let completed = ["a": start]
        let step = schedule.nextStep(targets: ["a", "neu"], completedAt: completed, attemptedAt: attempted,
                                     previousStep: start, now: start)
        #expect(step == .init(path: "neu", date: start.addingTimeInterval(schedule.retryPause - 10)))
    }

    /// Ein Zeitstempel in der Zukunft (Uhr zurückgestellt) ist nicht belastbar: Der Baum gilt als überfällig.
    @Test func overdueTargetsAreThoseWithoutRecentCompleteCheck() {
        let now = start.addingTimeInterval(schedule.maximumAge + 1)
        let completed = ["alt": start, "frisch": start.addingTimeInterval(10), "grenze": now.addingTimeInterval(-schedule.maximumAge),
                         "zukunft": now.addingTimeInterval(60)]
        #expect(schedule.overdueTargets(["alt", "frisch", "grenze", "nie", "zukunft"], completedAt: completed, now: now)
            == ["alt", "nie", "zukunft"])
    }

    /// Steht der letzte Schritt nach einer Zeitumstellung in der Zukunft, wartet der Plan höchstens einen Abstand.
    @Test func stepInTheFutureDoesNotStallThePlan() {
        let completed = ["a": start, "b": start]
        let step = try! #require(schedule.nextStep(targets: ["a", "b"], completedAt: completed, attemptedAt: [:],
                                                   previousStep: start.addingTimeInterval(3_600), now: start))
        #expect(step.date <= start.addingTimeInterval(schedule.period / 2))
    }

    /// Uhr zurückgestellt: Alle Prüfzeitpunkte liegen in der Zukunft und gelten als überfällig. Der Plan holt sie der
    /// Reihe nach zügig nach (die Engine reicht die Ziele nach ihrem letzten Planschritt geordnet herein), statt immer
    /// wieder den gerade geprüften Baum zu wählen, und kehrt dann zum Abstand zurück.
    @Test func clockSetBackStillVisitsEveryTreeInTurn() {
        var targets = ["a", "b", "c"]
        var completed = Dictionary(uniqueKeysWithValues: targets.map { ($0, start.addingTimeInterval(3_600)) })
        var now = start
        var previous = start
        var visited: [String] = []
        for _ in 0..<6 {
            let step = try! #require(schedule.nextStep(targets: targets, completedAt: completed, attemptedAt: [:],
                                                       previousStep: previous, now: now))
            #expect(step.date.timeIntervalSince(previous) <= schedule.gap(forTargetCount: targets.count))
            now = max(now, step.date)
            visited.append(step.path)
            completed[step.path] = now
            previous = now
            targets.removeAll { $0 == step.path }
            targets.append(step.path)
        }
        #expect(visited == ["a", "b", "c", "a", "b", "c"])
    }

    @Test func noTargetsNoStep() {
        #expect(schedule.nextStep(targets: [], completedAt: [:], attemptedAt: [:], previousStep: start, now: start) == nil)
    }

    // MARK: Sichtbare Livewerte (#662)

    /// Ohne sichtbare Livewerte zielt der Plan `lead` vor die Frist; sichtbare schieben bis zur Frist auf.
    @Test func visibleLiveViewsDeferUntilTheDeadline() {
        let completed = ["a": start, "b": start.addingTimeInterval(100)]
        let hidden = try! #require(schedule.nextStep(targets: ["a", "b"], completedAt: completed, attemptedAt: [:],
                                                     previousStep: start.addingTimeInterval(700), now: start.addingTimeInterval(700)))
        #expect(hidden == .init(path: "a", date: start.addingTimeInterval(schedule.period)))
        let visible = schedule.nextStep(targets: ["a", "b"], completedAt: completed, attemptedAt: [:],
                                        previousStep: start.addingTimeInterval(700), liveViews: .visible,
                                        now: start.addingTimeInterval(700))
        #expect(visible == .init(path: "a", date: start.addingTimeInterval(schedule.deadlineAge), isForced: true))
        #expect(schedule.deadlineAge - schedule.period == schedule.lead)
    }

    /// Nach dem Verdecken wartet der Plan `settle` – außer die Frist eines Baums endet vorher.
    @Test func settleDelaysHiddenStepsButNeverPastTheDeadline() {
        let now = start.addingTimeInterval(820)
        let completed = ["a": start, "b": start.addingTimeInterval(300)]
        let settling = schedule.nextStep(targets: ["a", "b"], completedAt: completed, attemptedAt: [:], previousStep: start,
                                         liveViews: .hidden(since: now), now: now)
        #expect(settling == .init(path: "a", date: start.addingTimeInterval(schedule.deadlineAge), isForced: true),
                "die Frist von a endet vor der Ruhezeit")
        let fresh = ["a": start.addingTimeInterval(500), "b": start.addingTimeInterval(600)]
        let calm = schedule.nextStep(targets: ["a", "b"], completedAt: fresh, attemptedAt: [:], previousStep: start,
                                     liveViews: .hidden(since: now), now: now)
        #expect(calm == .init(path: "a", date: now.addingTimeInterval(schedule.settle)))
    }

    /// Ein erzwungener Durchgang nimmt alle Bäume, die innerhalb von `forcedHorizon` beginnen müssen, früheste zuerst
    /// (je Baum `defaultTreeWork` Arbeit vor ihm).
    @Test func forcedOrderTakesTheTreesThatMustStartWithinTheHorizon() {
        let now = start.addingTimeInterval(schedule.deadlineAge)
        let completed = ["fällig": start, "bald": start.addingTimeInterval(schedule.forcedHorizon - 1),
                         "später": start.addingTimeInterval(schedule.forcedHorizon + 3 * schedule.defaultTreeWork + 1)]
        #expect(schedule.forcedOrder(["später", "bald", "nie", "fällig"], completedAt: completed, attemptedAt: [:], now: now)
            == ["nie", "fällig", "bald"])
    }

    /// Codex-Review zu PR 665: Zehn gleich alte Bäume mit je 6 s Arbeit (Blöcke samt Pausen) beginnen so früh, dass auch
    /// der letzte vor seiner Frist an der Reihe ist – nicht erst, wenn der erste seine Frist erreicht.
    @Test func forcedStartLeavesRoomForTheWorkOfEarlierTrees() {
        let targets = (0..<10).map { "t\($0)" }
        let completed = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1, start.addingTimeInterval(Double($0))) })
        let work = Dictionary(uniqueKeysWithValues: targets.map { ($0, 6.0) })
        let now = start.addingTimeInterval(100)
        let step = try! #require(schedule.nextStep(targets: targets, completedAt: completed, attemptedAt: [:],
                                                   previousStep: now, liveViews: .visible, work: work, now: now))
        #expect(step == .init(path: "t0", date: start.addingTimeInterval(schedule.deadlineAge + 9 - 9 * 6), isForced: true))
        #expect(schedule.forcedOrder(targets, completedAt: completed, attemptedAt: [:], work: work, now: step.date)
            == targets, "alle zehn im selben Durchgang")
        var begin = step.date
        for path in targets {
            let deadline = try! #require(completed[path]).addingTimeInterval(schedule.deadlineAge)
            #expect(begin <= deadline, "\(path) beginnt vor seiner Frist")
            begin.addTimeInterval(work[path] ?? 0)
        }
    }

    /// Die Pause zwischen zwei Blöcken entfällt nur, solange ein Baum seine Frist noch halten kann: ein wartender ab
    /// seinem spätesten Beginn, der laufende erst ab der halben Reserve (sie gehört seinen eigenen Blöcken).
    @Test func deadlineIsPressingBetweenTheLatestStartAndTheMaximumAge() {
        func pressing(_ age: TimeInterval?, running: Bool = false) -> Bool {
            schedule.deadlineIsPressing(completed: age.map { start.addingTimeInterval(-$0) }, running: running, now: start)
        }
        #expect(!pressing(schedule.deadlineAge + 1, running: true))
        #expect(pressing(schedule.deadlineAge + schedule.reserve / 2, running: true))
        #expect(!pressing(schedule.deadlineAge - 1))
        #expect(pressing(schedule.deadlineAge))
        #expect(pressing(schedule.maximumAge - 1))
        #expect(!pressing(schedule.maximumAge + 1), "überfällig: Nachholen im üblichen Takt")
        #expect(!pressing(nil))
        #expect(!pressing(-10), "Zeitstempel in der Zukunft")
    }

    /// Simuliert den Plan wie die Engine: Ein Schritt läuft zu seinem Zeitpunkt, ein erzwungener prüft `forcedOrder`,
    /// ein regulärer `blockSize` Bäume in Fristreihenfolge. `visible` sind die Zeiten mit sichtbaren Livewerten; die
    /// Engine plant bei jedem Wechsel neu (hier: Schritt am Wechsel abbrechen und neu fragen).
    private func simulateLiveViews(
        targets: [String], completedAt initial: [String: Date], until end: Date, visible: [Range<Date>],
        blockSize: Int = 1
    ) -> [(step: SignatureRevalidationSchedule.Step, path: String)] {
        func liveViews(at date: Date) -> SignatureRevalidationSchedule.LiveViews {
            if visible.contains(where: { $0.contains(date) }) { return .visible }
            return .hidden(since: visible.map(\.upperBound).filter { $0 <= date }.max())
        }
        var completedAt = initial
        var previous = start
        var previousBlock = 1
        var now = start
        var checks: [(step: SignatureRevalidationSchedule.Step, path: String)] = []
        while now < end, let step = schedule.nextStep(
            targets: targets, completedAt: completedAt, attemptedAt: [:], previousStep: previous,
            previousBlockSize: previousBlock, liveViews: liveViews(at: now), now: now
        ) {
            let change = visible.flatMap { [$0.lowerBound, $0.upperBound] }.filter { $0 > now }.min()
            if let change, change < step.date {
                now = change
                continue
            }
            now = max(now, step.date)
            let order = step.isForced
                ? schedule.forcedOrder(targets, completedAt: completedAt, attemptedAt: [:], now: now)
                : Array(schedule.dueOrder(targets, completedAt: completedAt, attemptedAt: [:], now: now).prefix(blockSize))
            for path in order {
                checks.append((step, path))
                completedAt[path] = now
            }
            previous = now
            previousBlock = order.count
        }
        return checks
    }

    private func randomStart(_ targets: [String], seed: Int) -> [String: Date] {
        var generator = SeededGenerator(seed: UInt64(seed))
        var completed: [String: Date] = [:]
        for target in targets where Int.random(in: 0..<10, using: &generator) > 0 {
            completed[target] = start.addingTimeInterval(-TimeInterval.random(in: 0...schedule.deadlineAge, using: &generator))
        }
        return completed
    }

    private func expectDeadlineKept(_ checks: [(step: SignatureRevalidationSchedule.Step, path: String)],
                                    targets: [String], completedAt: [String: Date], until end: Date,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        for target in targets {
            let dates = [completedAt[target]].compactMap(\.self) + checks.filter { $0.path == target }.map(\.step.date)
            let gaps = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }
            #expect(gaps.allSatisfy { $0 <= schedule.maximumAge }, "\(target): \(gaps)", sourceLocation: sourceLocation)
            #expect(end.timeIntervalSince(dates.last ?? start) <= schedule.maximumAge, "\(target)",
                    sourceLocation: sourceLocation)
        }
    }

    /// Dauerhaft sichtbar über drei Stunden, verschiedene Ausgangslagen: Jeder Schritt ist erzwungen, die Zusage hält,
    /// und Durchgänge liegen mindestens `forcedHorizon` auseinander (wenige, dafür mehrere Bäume).
    @Test(arguments: [0, 1, 2, 3])
    func permanentlyVisibleKeepsEveryDeadlineInFewPasses(seed: Int) {
        let targets = (0..<61).map { "/Applications/App\($0).app" }
        let completed = randomStart(targets, seed: seed)
        let end = start.addingTimeInterval(3 * 3_600)
        let checks = simulateLiveViews(targets: targets, completedAt: completed, until: end,
                                       visible: [start..<end.addingTimeInterval(1)])
        #expect(checks.allSatisfy { $0.step.isForced })
        expectDeadlineKept(checks, targets: targets, completedAt: completed, until: end)
        let passes = Set(checks.map(\.step.date)).sorted()
        #expect(zip(passes, passes.dropFirst()).dropFirst().allSatisfy {
            $1.timeIntervalSince($0) >= schedule.forcedHorizon - 0.001
        }, "nach dem Nachholen höchstens ein Durchgang je forcedHorizon")
    }

    /// Sichtbar und verdeckt im Wechsel (5 min sichtbar, 2 min verdeckt): Sichtbar und in der Ruhezeit nur erzwungene
    /// Schritte, die Zusage hält.
    @Test(arguments: [0, 1, 2])
    func alternatingVisibilityKeepsEveryDeadline(seed: Int) {
        let targets = (0..<61).map { "/Applications/App\($0).app" }
        let completed = randomStart(targets, seed: seed)
        let end = start.addingTimeInterval(3 * 3_600)
        let visible = stride(from: 0.0, to: 3 * 3_600, by: 420).map {
            start.addingTimeInterval($0)..<start.addingTimeInterval($0 + 300)
        }
        let checks = simulateLiveViews(targets: targets, completedAt: completed, until: end, visible: visible, blockSize: 8)
        expectDeadlineKept(checks, targets: targets, completedAt: completed, until: end)
        for check in checks where !check.step.isForced {
            #expect(!visible.contains { $0.contains(check.step.date) }, "verdeckt")
            #expect(!visible.contains {
                check.step.date >= $0.upperBound && check.step.date < $0.upperBound.addingTimeInterval(schedule.settle)
            }, "nach der Ruhezeit")
        }
        #expect(checks.contains { check in !visible.contains { $0.contains(check.step.date) } }, "auch verdeckt geprüft")
    }

    /// Ohne sichtbare Livewerte prüft der Plan im eingeschwungenen Zustand mit Vorlauf: jeder Baum nach höchstens
    /// `period` plus einem Abstand, also deutlich vor der Frist.
    @Test func hiddenPaceRunsTheLeadAheadOfTheDeadline() {
        let targets = (0..<61).map { "/Applications/App\($0).app" }
        let completed = Dictionary(uniqueKeysWithValues: targets.map { ($0, start) })
        let end = start.addingTimeInterval(3 * 3_600)
        let checks = simulateLiveViews(targets: targets, completedAt: completed, until: end, visible: [], blockSize: 8)
        let settled = start.addingTimeInterval(2 * schedule.period)
        let gap = schedule.gap(forTargetCount: targets.count)
        for target in targets {
            let dates = checks.filter { $0.path == target }.map(\.step.date)
            let gaps = zip(dates, dates.dropFirst()).filter { $0.0 >= settled }.map { $1.timeIntervalSince($0) }
            #expect(gaps.allSatisfy { $0 <= schedule.period + gap + 0.001 }, "\(target): \(gaps)")
        }
        #expect(checks.allSatisfy { !$0.step.isForced })
    }
}

/// Welche Bäume ein Vollscan komplett prüft (#649): Start und manueller Scan alle, eine Dateiänderung den Baum, in dem
/// sie liegt, Intervall- und Teilscans keinen (nur Bundle-Stempel).
@Suite struct CompleteTreeSelectionTests {
    let targets = ["/Applications/App.app", "/Applications/App.app2", "/Users/u/Applications/Tool.app"]

    @Test func reasonsSelectTrees() {
        #expect(CompleteTreeSelection(.launch).targets(in: targets) == Set(targets))
        #expect(CompleteTreeSelection(.manual).targets(in: targets) == Set(targets))
        #expect(CompleteTreeSelection(.interval).targets(in: targets).isEmpty)
        #expect(CompleteTreeSelection(.sourceRefresh([.networkListeners])).targets(in: targets).isEmpty)
        #expect(CompleteTreeSelection(.fileChange(path: "/Applications/App.app/Contents")).targets(in: targets)
            == ["/Applications/App.app"], "nicht App.app2 mit gleichem Anfang")
        #expect(CompleteTreeSelection(.fileChange(path: "/Applications/App.app")).targets(in: targets)
            == ["/Applications/App.app"])
        #expect(CompleteTreeSelection(.fileChange(path: "/Applications")).targets(in: targets).isEmpty,
                "Elternordner: kein Ziel erkennbar, Austausch erkennen die Stempel")
    }

    /// Zusammengefasste Anlässe prüfen die Vereinigung: Ein manueller Scan geht nicht in einer späteren
    /// Dateiänderung auf, zwei Dateiänderungen prüfen beide Bäume.
    @Test func mergedReasonsCheckTheUnion() {
        let manual = CompleteTreeSelection(.manual)
        let file = CompleteTreeSelection(.fileChange(path: "/Applications/App.app/Contents/Info.plist"))
        let other = CompleteTreeSelection(.fileChange(path: "/Users/u/Applications/Tool.app/Contents"))
        #expect(manual.union(file) == .all)
        #expect(file.union(manual) == .all)
        #expect(file.union(other).targets(in: targets) == ["/Applications/App.app", "/Users/u/Applications/Tool.app"])
        #expect(file.union(CompleteTreeSelection(.interval)) == file)
    }
}

/// Reproduzierbarer Zufall für die Ausgangslagen.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
