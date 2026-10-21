import Foundation
import Testing
@testable import ManagerKit

/// Fixtures use seconds since scan start; no sleeps, live sources or real app state.
@Suite struct ScanProgressTests {
    private let sources: Set<SourceID> = [.launchd, .tccSystem]
    private let history = ScanDurations(sources: [.launchd: 2, .tccSystem: 8], processing: 2)

    @Test func remainingTimeExpiresWithoutAnotherSourceCompletion() throws {
        var scan = ScanProgressTracker(sources: sources, previous: history)
        _ = scan.complete(.launchd, elapsed: 2, succeeded: true)
        let published = scan.progress
        let deadline = try #require(published.estimateExpiresAt)
        #expect(published.remainingSeconds(at: deadline.advanced(by: .nanoseconds(-1))) == 8)
        // No more source completions: the same published value must expire on its own.
        #expect(published.remainingSeconds(at: deadline) == nil)
        #expect(published.remainingSeconds(at: deadline.advanced(by: .seconds(120))) == nil)
        #expect(scan.progress.fraction == published.fraction)
    }

    @Test func expiredEstimateIsNotRevivedWhenProcessingGetsANewEstimate() throws {
        var scan = ScanProgressTracker(sources: sources, previous: history)
        _ = scan.complete(.launchd, elapsed: 2, succeeded: true)
        let firstDeadline = try #require(scan.progress.estimateExpiresAt)
        #expect(scan.progress.remainingSeconds(at: firstDeadline) == nil)
        _ = scan.complete(.tccSystem, elapsed: 8, succeeded: true)
        let processingDeadline = try #require(scan.progress.estimateExpiresAt)
        #expect(scan.progress.remainingSeconds(at: processingDeadline) == nil)
        scan.finish(elapsed: 10)
        #expect(scan.progress.estimateExpiresAt == nil)
        #expect(scan.progress.fraction == 1)
    }

    @Test func remainingTimeUsesTheSuppliedMonotonicInstant() {
        let now = ContinuousClock.now
        let progress = ScanProgress(fraction: 0.25, remainingSeconds: 8, now: now)
        #expect(progress.estimateExpiresAt == now.advanced(by: .seconds(8)))
        #expect(progress.remainingSeconds(at: now) == 8)
        let expired = ScanProgress(fraction: 0.25, remainingSeconds: 8,
                                   now: now.advanced(by: .seconds(-20)))
        #expect(expired.remainingSeconds == nil)
        #expect(expired.fraction == 0.25)
    }

    @Test func firstScanCountsStepsWithoutInventingRemainingTime() {
        var scan = ScanProgressTracker(sources: sources, previous: nil)
        #expect(scan.progress.fraction == 0)
        #expect(scan.progress.remainingSeconds == nil)
        _ = scan.complete(.launchd, elapsed: 2, succeeded: true)
        #expect(abs(scan.progress.fraction - 1.0 / 3) < 0.0001)
        #expect(scan.progress.remainingSeconds == nil)
        _ = scan.complete(.tccSystem, elapsed: 8, succeeded: true)
        scan.finish(elapsed: 10)
        #expect(scan.progress.fraction == 1)
        #expect(scan.completedDurations?.processing == 2)
    }

    @Test func weightsCompletedSourcesAndEstimatesParallelCriticalPath() {
        var scan = ScanProgressTracker(sources: sources, previous: history)
        _ = scan.complete(.launchd, elapsed: 2, succeeded: true)
        #expect(abs(scan.progress.fraction - 2.0 / 12) < 0.0001)
        // 8 s parallel source - 2 s elapsed + 2 s processing, not a sum of source durations.
        #expect(scan.progress.remainingSeconds == 8)
        _ = scan.complete(.tccSystem, elapsed: 8, succeeded: true)
        #expect(abs(scan.progress.fraction - 10.0 / 12) < 0.0001)
        #expect(scan.progress.remainingSeconds == 2)
        scan.finish(elapsed: 10)
        #expect(scan.progress.fraction == 1)
    }

    @Test(arguments: [0.5, 2.0]) func adjustsEstimateForFasterAndSlowerScans(pace: Double) {
        var scan = ScanProgressTracker(sources: sources, previous: history)
        _ = scan.complete(.launchd, elapsed: 2 * pace, succeeded: true)
        #expect(scan.progress.remainingSeconds == 8 * pace)
    }

    @Test func suppressesUncertainEstimatesAndNeverGoesBackwards() {
        var scan = ScanProgressTracker(sources: sources, previous: history)
        _ = scan.complete(.launchd, elapsed: 0.01, succeeded: true)
        let first = scan.progress.fraction
        #expect(scan.progress.remainingSeconds == nil)
        _ = scan.complete(.tccSystem, elapsed: 100, succeeded: true)
        #expect(scan.progress.fraction >= first)
        #expect(scan.progress.remainingSeconds == nil)
        scan.finish(elapsed: 101)
        #expect(scan.progress.fraction == 1)
    }

    @Test func cancellationDoesNotReportSuccessOrReplaceTimingHistory() {
        var scan = ScanProgressTracker(sources: sources, previous: history)
        _ = scan.complete(.launchd, elapsed: 2, succeeded: true)
        scan.cancel()
        #expect(scan.progress.fraction < 1)
        #expect(scan.progress.remainingSeconds == nil)
        #expect(scan.progress.estimateExpiresAt == nil)
        #expect(scan.completedDurations == nil)
        let publishedAfterCancel = scan.complete(.tccSystem, elapsed: 8, succeeded: true)
        #expect(!publishedAfterCancel)
    }

    @Test func throttlesPublicationsButKeepsEveryCompletionAndFinishesImmediately() {
        let ids = Set((0..<20).map { SourceID(rawValue: "fixture-\($0)") })
        var scan = ScanProgressTracker(sources: ids, previous: nil)
        var publications = 0
        for (index, id) in ids.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            if scan.complete(id, elapsed: Double(index + 1) / 100, succeeded: true) { publications += 1 }
        }
        #expect(publications == 0) // initial state published at t=0; next permitted at t=0.25
        #expect(scan.progress.fraction > 0.9)
        scan.finish(elapsed: 0.21)
        #expect(scan.progress.fraction == 1)
        #expect(scan.completedDurations?.sources.count == 20)
        let publishedAfterFinish = scan.complete(ids.first!, elapsed: 1, succeeded: true)
        #expect(!publishedAfterFinish)
    }

    @Test func publishesAtMostOncePerQuarterSecondAndAllowsNextWindow() {
        let ids: Set<SourceID> = [.launchd, .tccSystem, .apps, .btm]
        var scan = ScanProgressTracker(sources: ids, previous: nil)
        let first = scan.complete(.launchd, elapsed: 0.25, succeeded: true)
        let tooSoon = scan.complete(.tccSystem, elapsed: 0.30, succeeded: true)
        let nextWindow = scan.complete(.apps, elapsed: 0.50, succeeded: true)
        #expect(first)
        #expect(!tooSoon)
        #expect(nextWindow)
        #expect(abs(scan.progress.fraction - 0.6) < 0.0001)
    }

    @Test func failedAndDuplicateStepsCannotTrainOrAdvanceTwice() {
        var scan = ScanProgressTracker(sources: sources, previous: history)
        _ = scan.complete(.launchd, elapsed: 2, succeeded: false)
        let fraction = scan.progress.fraction
        _ = scan.complete(.launchd, elapsed: 3, succeeded: true)
        #expect(scan.progress.fraction == fraction)
        #expect(scan.progress.remainingSeconds == nil)
        _ = scan.complete(.tccSystem, elapsed: 8, succeeded: true)
        scan.finish(elapsed: 9)
        #expect(scan.progress.fraction == 1)
        #expect(scan.completedDurations == nil)
    }

    @Test func incompleteOrInvalidHistoryFallsBackToStepCounting() {
        for previous in [ScanDurations(sources: [.launchd: 2], processing: 1),
                         ScanDurations(sources: [.launchd: .nan, .tccSystem: 8], processing: 1)] {
            var scan = ScanProgressTracker(sources: sources, previous: previous)
            _ = scan.complete(.launchd, elapsed: 2, succeeded: true)
            #expect(abs(scan.progress.fraction - 1.0 / 3) < 0.0001)
            #expect(scan.progress.remainingSeconds == nil)
        }
    }
}

@Suite struct ScanProgressIntegrationTests {
    @Test func coordinatorReportsRealSourcesIncludingFailuresExactlyOnce() async throws {
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .launchd, result: .success(InventoryContribution())),
            FixedSource(id: .tccSystem, result: .failure(TestFailure()))
        ])
        let (events, continuation) = AsyncStream<ScanSourceCompletion>.makeStream()
        let snapshot = try await coordinator.scan { completion in continuation.yield(completion) }
        continuation.finish()
        var received: [ScanSourceCompletion] = []
        for await event in events { received.append(event) }
        #expect(Set(received.map(\.source)) == [.launchd, .tccSystem])
        #expect(received.count == 2)
        #expect(received.first { $0.source == .launchd }?.succeeded == true)
        #expect(received.first { $0.source == .tccSystem }?.succeeded == false)
        #expect(received.allSatisfy { $0.elapsed >= 0 })
        #expect(snapshot.sourceErrors.count == 1)
    }

    @Test func durationStoreKeepsOnlyOneBoundedValidatedSample() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "ScanDurations.json")
        let store = ScanDurationStore(url: url)
        let first = ScanDurations(sources: [.launchd: 2, .tccSystem: 8], processing: 1)
        store.save(first)
        #expect(store.load() == first)
        let second = ScanDurations(sources: [.launchd: 3], processing: 2)
        store.save(second)
        #expect(store.load() == second)
        #expect(try Data(contentsOf: url).count < 2048)
        try Data("invalid".utf8).write(to: url)
        #expect(store.load() == nil)
    }
}
