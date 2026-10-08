import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Zählt Aufrufe; liefert der Reihe nach `results` (der letzte wiederholt sich).
private final class ScriptedSizer: FileSizeMeasuring {
    private let state: Mutex<(results: [Int64?], calls: Int)>
    init(_ results: [Int64?]) { state = Mutex((results, 0)) }
    var calls: Int { state.withLock { $0.calls } }
    func allocatedSize(of path: String) -> Int64? {
        state.withLock { state in
            state.calls += 1
            return state.results.count > 1 ? state.results.removeFirst() : state.results.first ?? nil
        }
    }
}

private final class CountingLastUsed: LastUsedReading {
    private let count = Mutex(0)
    /// Wird bei jedem Aufruf geöffnet. Suspendiert statt zu blockieren: Ein blockierendes Warten im kooperativen Pool
    /// sperrte bei wenigen Kernen genau den Task aus, der den Aufruf auslöst.
    private let called = Gate()
    /// Kehrt zurück, sobald ein Aufruf kam (begrenzt durch die Zeitgrenze des Tests).
    func waitForCall() async throws { try await called.wait() }
    var calls: Int { count.withLock { $0 } }
    func lastUsed(ofBundleAt path: String) -> Date? {
        defer { called.open() }
        return count.withLock { $0 += 1; return TestData.date.addingTimeInterval(TimeInterval($0)) }
    }
}

/// Größe, die erst nach `release` antwortet.
private final class BlockingSizer: FileSizeMeasuring {
    let release = DispatchSemaphore(value: 0)
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    func allocatedSize(of path: String) -> Int64? {
        count.withLock { $0 += 1 }
        release.wait()
        return 42
    }
}

@Suite struct AppDetailsLoaderTests {
    @Test func sizeIsCachedUntilTheBundleChanges() async throws {
        try await ScratchDirectory.with(prefix: "details") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            try AppBundleFixture.pin(bundle)
            let sizer = ScriptedSizer([100, 200])
            let loader = AppDetailsLoader(sizes: sizer, lastUsed: CountingLastUsed())
            #expect(await loader.details(for: bundle.path).size == 100)
            #expect(await loader.details(for: bundle.path).size == 100)
            #expect(await loader.cachedSizes(for: [bundle.path]) == [bundle.path: 100])
            #expect(sizer.calls == 1)
            try AppBundleFixture.pin(bundle, plistModified: AppBundleFixture.pinnedDate.addingTimeInterval(60))
            #expect(await loader.details(for: bundle.path).size == 200)
        }
    }

    @Test func timeoutIsNotCached() async throws {
        try await ScratchDirectory.with(prefix: "details") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            let sizer = ScriptedSizer([nil, 300])
            let loader = AppDetailsLoader(sizes: sizer, lastUsed: CountingLastUsed())
            #expect(await loader.details(for: bundle.path).size == nil)
            #expect(await loader.details(for: bundle.path).size == 300)
        }
    }

    @Test func lastUsedIsReadEveryTime() async throws {
        try await ScratchDirectory.with(prefix: "details") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            let loader = AppDetailsLoader(sizes: ScriptedSizer([1]), lastUsed: CountingLastUsed())
            let first = await loader.details(for: bundle.path).lastUsed
            let second = await loader.details(for: bundle.path).lastUsed
            #expect(first != second)
        }
    }

    @Test func missingBundleHasNoSize() async {
        let sizer = ScriptedSizer([1])
        let loader = AppDetailsLoader(sizes: sizer, lastUsed: CountingLastUsed())
        #expect(await loader.details(for: "/does/not/exist.app").size == nil)
        #expect(sizer.calls == 0)
    }

    /// Review N1: „Zuletzt benutzt“ wartet nicht hinter einer langen Größenberechnung.
    @Test(.timeLimit(.minutes(1))) func lastUsedIsNotQueuedBehindSize() async throws {
        try await ScratchDirectory.with(prefix: "details") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            let sizer = BlockingSizer()
            let lastUsed = CountingLastUsed()
            let loader = AppDetailsLoader(sizes: sizer, lastUsed: lastUsed)
            let path = bundle.path
            let details = Task { await loader.details(for: path) }
            try await lastUsed.waitForCall()
            sizer.release.signal()
            #expect(await details.value.size == 42)
        }
    }

    /// Gleichzeitige Anfragen für denselben Pfad teilen sich eine Berechnung.
    @Test(.timeLimit(.minutes(1))) func concurrentRequestsShareOneLoad() async throws {
        try await ScratchDirectory.with(prefix: "details") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            let sizer = BlockingSizer()
            let lastUsed = CountingLastUsed()
            let loader = AppDetailsLoader(sizes: sizer, lastUsed: lastUsed)
            let path = bundle.path
            let requests = (0..<5).map { _ in Task { await loader.details(for: path) } }
            try await lastUsed.waitForCall()
            try await Task.sleep(for: .milliseconds(50))
            sizer.release.signal()
            for request in requests { #expect(await request.value.size == 42) }
            #expect(sizer.calls == 1)
            #expect(lastUsed.calls == 1)
        }
    }

    /// Ein abgebrochener Aufrufer reiht nichts mehr ein.
    @Test func cancelledRequestEnqueuesNothing() async throws {
        try await ScratchDirectory.with(prefix: "details") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            let sizer = ScriptedSizer([1])
            let lastUsed = CountingLastUsed()
            let loader = AppDetailsLoader(sizes: sizer, lastUsed: lastUsed)
            let path = bundle.path
            let details = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await loader.details(for: path)
            }.value
            #expect(details == AppUsageDetails())
            #expect(sizer.calls == 0)
            #expect(lastUsed.calls == 0)
        }
    }

    /// Symlink-Bundles (Review M3): Dem Ziel folgt weder Größe noch Spotlight.
    @Test func symlinkedBundleIsNotFollowed() async throws {
        try await ScratchDirectory.with(prefix: "details") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            let link = directory.appending(path: "Link.app")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
            let sizer = ScriptedSizer([1])
            let lastUsed = CountingLastUsed()
            let loader = AppDetailsLoader(sizes: sizer, lastUsed: lastUsed)
            #expect(await loader.details(for: link.path) == AppUsageDetails())
            #expect(sizer.calls == 0)
            #expect(lastUsed.calls == 0)
        }
    }
}
