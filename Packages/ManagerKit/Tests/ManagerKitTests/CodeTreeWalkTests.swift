import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// #662: Die Komplettprüfung liest einen großen Code-Baum in Abschnitten bis zu einem CPU-Budget und setzt im nächsten
/// Block fort. Der Fingerabdruck in Abschnitten gleicht dem am Stück (`CodeTreeFingerprint.read`), Grenzen und Fehler
/// gelten wie dort.
@Suite struct CodeTreeWalkTests {
    /// Bundle mit `count` Ressourcen: genug Einträge für mehrere Abschnitte.
    private func bundle(in directory: URL, resources count: Int) throws -> URL {
        let resources = Dictionary(uniqueKeysWithValues: (0..<count).map { ("r\($0).txt", "\($0)") })
        return try Codesign.bundle(in: directory, named: "Walk", adHoc: true, resources: resources)
    }

    /// Bis zum Ende: Zahl der Abschnitte und das Ergebnis.
    private func finish(_ walk: CodeTreeWalk, budget: Duration?) -> (chunks: Int, fingerprint: String?) {
        var chunks = 0
        while true {
            chunks += 1
            let step = walk.advance(cpuBudget: budget)
            #expect(step.cpuTime >= .zero)
            if case .finished(let fingerprint) = step.progress { return (chunks, fingerprint) }
            #expect(chunks < 10_000, "kein Fortschritt")
            if chunks >= 10_000 { return (chunks, nil) }
        }
    }

    @Test func walkInChunksMatchesTheWholeTraversal() throws {
        try ScratchDirectory.withCanonical(prefix: "walk-chunks") { directory in
            let app = try bundle(in: directory, resources: 40)
            let whole = try #require(CodeTreeFingerprint.read(at: app.path))
            let walk = try #require(CodeTreeWalk(path: app.path, checkInterval: 1))
            let result = finish(walk, budget: .nanoseconds(1))
            #expect(result.fingerprint == whole)
            #expect(result.chunks > 10, "ein Abschnitt je Eintrag bei kleinstem Budget, nicht am Stück")
        }
    }

    @Test func walkWithoutBudgetFinishesInOneChunk() throws {
        try ScratchDirectory.withCanonical(prefix: "walk-whole") { directory in
            let app = try bundle(in: directory, resources: 5)
            let walk = try #require(CodeTreeWalk(path: app.path))
            let result = finish(walk, budget: nil)
            #expect(result.chunks == 1)
            #expect(result.fingerprint == CodeTreeFingerprint.read(at: app.path))
        }
    }

    /// Nach dem Ende bleibt das Ergebnis stehen; ein weiterer Aufruf liest nichts mehr.
    @Test func finishedWalkKeepsItsResult() throws {
        try ScratchDirectory.withCanonical(prefix: "walk-finished") { directory in
            let app = try bundle(in: directory, resources: 2)
            let walk = try #require(CodeTreeWalk(path: app.path))
            let first = walk.advance(cpuBudget: nil)
            let second = walk.advance(cpuBudget: .nanoseconds(1))
            #expect(first.progress == second.progress)
            #expect(second.cpuTime == .zero)
        }
    }

    /// Grenzen wie am Stück: Die Zahl der Einträge und die aktive Lesezeit (ohne die Pausen zwischen den Blöcken)
    /// verhindern jede Cache-Wiederverwendung.
    @Test func limitsSpanAllChunks() throws {
        try ScratchDirectory.withCanonical(prefix: "walk-limits") { directory in
            let app = try bundle(in: directory, resources: 20)
            let limited = try #require(CodeTreeWalk(path: app.path, maximumEntries: 5, checkInterval: 1))
            #expect(finish(limited, budget: .nanoseconds(1)).fingerprint == nil)
            let timedOut = try #require(CodeTreeWalk(path: app.path, timeout: .zero, checkInterval: 1))
            #expect(finish(timedOut, budget: .nanoseconds(1)).fingerprint == nil)
        }
    }

    /// Ein Eintrag, der zwischen zwei Abschnitten im noch nicht gelesenen Teil entsteht, ändert den Fingerabdruck.
    @Test func changeInTheUnreadPartChangesTheFingerprint() throws {
        try ScratchDirectory.withCanonical(prefix: "walk-change") { directory in
            let app = try bundle(in: directory, resources: 30)
            let whole = try #require(CodeTreeFingerprint.read(at: app.path))
            let walk = try #require(CodeTreeWalk(path: app.path, checkInterval: 1))
            #expect(walk.advance(cpuBudget: .nanoseconds(1)).progress == .partial)
            try Data("neu".utf8).write(to: app.appending(path: "Contents/Resources/r9.txt"))
            #expect(finish(walk, budget: nil).fingerprint != whole)
        }
    }

    @Test func missingTreeHasNoWalk() {
        #expect(CodeTreeWalk(path: "/does/not/exist-\(UUID().uuidString).app")?.advance(cpuBudget: nil).progress
            ?? .finished(nil) == .finished(nil))
    }
}
