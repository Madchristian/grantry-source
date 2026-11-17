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
