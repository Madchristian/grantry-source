import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// #662: Die Komplettprüfung eines Baums läuft in Blöcken bis zu einem CPU-Budget (`DeepSignatureVerifier
/// .revalidateTree(at:cpuBudget:)`). Ein großer Baum setzt im nächsten Block fort; erst der letzte Block macht ihn zu
/// einem geprüften Baum, datiert auf den Beginn des ersten. Ändert er sich zwischen zwei Blöcken, gilt er nicht als
/// geprüft, und die Prüfung beginnt neu.
@Suite(.timeLimit(.minutes(1)))
struct TreeRevalidationBlockTests {
    private let budget = Duration.milliseconds(250)

    private func verifier(clock: TestClock, walks: ScriptedTreeWalks) -> DeepSignatureVerifier {
        DeepSignatureVerifier(validator: ScriptedSignatureValidator(), clock: clock,
                              treeFingerprint: { CodeTreeFingerprint.read(at: $0) }, treeWalk: walks.factory)
    }

    @Test func largeTreeContinuesAcrossBlocksAndIsDatedFromTheFirst() async throws {
        try await ScratchDirectory.with(prefix: "blocks-resume") { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Big", adHoc: true, resources: ["r.txt": "x"])
            let clock = TestClock()
            let walks = ScriptedTreeWalks(cost: { _ in .milliseconds(600) })
            let verifier = verifier(clock: clock, walks: walks)
            #expect(await verifier.verify(path: bundle.path) == .valid)
            clock.advance(by: .seconds(100))

            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget) == .init(outcome: .partial, cpuTime: budget))
            #expect(await verifier.completeCheckAges(for: [bundle.path]) == [bundle.path: 100], "halb geprüft zählt nicht")
            clock.advance(by: .seconds(5))
            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget).outcome == .partial)
            clock.advance(by: .seconds(5))
            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget)
                == .init(outcome: .finished(.valid), cpuTime: .milliseconds(100)))
            #expect(await verifier.completeCheckAges(for: [bundle.path]) == [bundle.path: 10], "ab Beginn des ersten Blocks")
            #expect(walks.walks.count == 1, "ein Durchlauf, fortgesetzt")
            #expect(walks.advances.allSatisfy { $0.qos == QOS_CLASS_BACKGROUND })
            #expect(walks.advances.allSatisfy { $0.cpuTime <= budget })
        }
    }

    /// Bundle-Stempel geändert (hier `Info.plist`): Der halb geprüfte Baum verfällt, er gilt nicht als geprüft, und der
    /// nächste Block beginnt von vorn – mit verändertem Baum ohne Bestätigung (Tiefenprüfung folgt).
    @Test func changeBetweenBlocksDiscardsTheHalfCheckedTree() async throws {
        try await ScratchDirectory.with(prefix: "blocks-change") { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Changing", adHoc: true, resources: ["r.txt": "x"])
            let clock = TestClock()
            let walks = ScriptedTreeWalks(cost: { _ in .milliseconds(600) })
            let verifier = verifier(clock: clock, walks: walks)
            #expect(await verifier.verify(path: bundle.path) == .valid)
            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget).outcome == .partial)

            try Data("<plist/>".utf8).write(to: bundle.appending(path: "Contents/Info.plist"))
            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget).outcome == .finished(nil))
            #expect(await verifier.completeCheckAges(for: [bundle.path]).isEmpty, "nicht als geprüft")
            #expect(await verifier.cachedVerdicts(for: [bundle.path], revalidation: .bundleMetadata).isEmpty)

            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget).outcome == .partial)
            #expect(walks.walks.count == 2, "beginnt neu")
        }
    }

    /// Mit dem echten Durchlauf: Eine Ressource im noch nicht gelesenen Teil (kein Stempel) ändert sich zwischen zwei
    /// Blöcken – der Fingerabdruck am Ende passt nicht mehr, der Baum gilt nicht als geprüft.
    @Test func realWalkCatchesAChangeInTheUnreadPart() async throws {
        try await ScratchDirectory.with(prefix: "blocks-real") { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Real", adHoc: true, resources: ["r.txt": "x"])
            let verifier = DeepSignatureVerifier(validator: ScriptedSignatureValidator(), clock: TestClock(),
                                                 treeFingerprint: { CodeTreeFingerprint.read(at: $0) },
                                                 treeWalk: { CodeTreeWalk(path: $0, checkInterval: 1) })
            #expect(await verifier.verify(path: bundle.path) == .valid)
            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: .nanoseconds(1)).outcome == .partial)
            try Data("verändert".utf8).write(to: bundle.appending(path: "Contents/Resources/r.txt"))
            var outcome = TreeRevalidationStep.Outcome.partial
            for _ in 0..<100 where outcome == .partial {
                outcome = await verifier.revalidateTree(at: bundle.path, cpuBudget: .nanoseconds(1)).outcome
            }
            #expect(outcome == .finished(nil))
            #expect(await verifier.completeCheckAges(for: [bundle.path]).isEmpty)
        }
    }

    /// Unverändert mit dem echten Durchlauf in kleinsten Blöcken: dasselbe Urteil wie am Stück.
    @Test func realWalkInBlocksConfirmsAnUnchangedTree() async throws {
        try await ScratchDirectory.with(prefix: "blocks-real-same") { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Same", adHoc: true, resources: ["r.txt": "x"])
            let verifier = DeepSignatureVerifier(validator: ScriptedSignatureValidator(), clock: TestClock(),
                                                 treeFingerprint: { CodeTreeFingerprint.read(at: $0) },
                                                 treeWalk: { CodeTreeWalk(path: $0, checkInterval: 1) })
            #expect(await verifier.verify(path: bundle.path) == .valid)
            var blocks = 0
            var outcome = TreeRevalidationStep.Outcome.partial
            while outcome == .partial, blocks < 100 {
                blocks += 1
                outcome = await verifier.revalidateTree(at: bundle.path, cpuBudget: .nanoseconds(1)).outcome
            }
            #expect(outcome == .finished(.valid))
            #expect(blocks > 3)
        }
    }

    /// Prüft ein Scan den Baum zwischendurch komplett, verfällt der angefangene Durchlauf.
    @Test func completeCheckInBetweenRestartsTheWalk() async throws {
        try await ScratchDirectory.with(prefix: "blocks-scan") { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Scanned", adHoc: true)
            let clock = TestClock()
            let walks = ScriptedTreeWalks(cost: { _ in .milliseconds(600) })
            let verifier = verifier(clock: clock, walks: walks)
            _ = await verifier.verify(path: bundle.path)
            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget).outcome == .partial)
            clock.advance(by: .seconds(30))
            #expect(await verifier.cachedVerdicts(for: [bundle.path], revalidation: .completeTree) == [bundle.path: .valid])
            #expect(await verifier.completeCheckAges(for: [bundle.path]) == [bundle.path: 0])
            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget).outcome == .partial)
            #expect(walks.walks.count == 2)
        }
    }

    /// Höchstens ein angefangener Baum im Speicher: Beginnt ein anderer, verfällt der erste.
    @Test func onlyOneHalfCheckedTreeIsKept() async throws {
        try await ScratchDirectory.with(prefix: "blocks-one") { directory in
            let first = try Codesign.bundle(in: directory, named: "First", adHoc: true)
            let second = try Codesign.bundle(in: directory, named: "Second", adHoc: true)
            let walks = ScriptedTreeWalks(cost: { _ in .milliseconds(600) })
            let verifier = verifier(clock: TestClock(), walks: walks)
            _ = await verifier.verify(path: first.path)
            _ = await verifier.verify(path: second.path)
            #expect(await verifier.revalidateTree(at: first.path, cpuBudget: budget).outcome == .partial)
            #expect(await verifier.revalidateTree(at: second.path, cpuBudget: budget).outcome == .partial)
            #expect(await verifier.revalidateTree(at: first.path, cpuBudget: budget).outcome == .partial)
            #expect(walks.walks.map(\.path) == [first.path, second.path, first.path].map {
                FileFingerprint.target(of: $0)
            })
        }
    }

    /// Ohne Cache-Eintrag gibt es nichts zu bestätigen: kein Durchlauf, die Tiefenprüfung folgt.
    @Test func treeWithoutCacheEntryNeedsTheDeepCheck() async throws {
        try await ScratchDirectory.with(prefix: "blocks-none") { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Unknown", adHoc: true)
            let walks = ScriptedTreeWalks(cost: { _ in .milliseconds(600) })
            let verifier = verifier(clock: TestClock(), walks: walks)
            #expect(await verifier.revalidateTree(at: bundle.path, cpuBudget: budget) == .init(outcome: .finished(nil),
                                                                                             cpuTime: .zero))
            #expect(walks.walks.isEmpty)
        }
    }
}
