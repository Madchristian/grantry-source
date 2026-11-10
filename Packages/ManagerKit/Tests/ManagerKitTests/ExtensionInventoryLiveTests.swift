import Foundation
import Testing
@testable import ManagerKit

/// Opt-in gegen das echte System (`MANAGERKIT_LIVE=1`), rein lesend und ohne Root: Mehrzeit der Erweiterungs-Quelle im
/// Scan (TM-13.3, Grenze 500 ms Wanduhr). Gemessen werden der erste Lauf einer neuen Quelle (Signaturen noch nicht
/// gepuffert), Median und Maximum aus 5 weiteren Läufen sowie ein Vollscan mit und ohne die Quelle neben dem
/// App-Inventar – die Differenz ist die Mehrzeit, die der Scan tatsächlich spürt.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"), .serialized)
struct ExtensionInventoryLiveTests {
    private static let budgetMilliseconds = 500.0

    private func milliseconds(_ body: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await body()
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    /// Median und Maximum aus 5 Läufen.
    private func measure(_ body: () async throws -> Void) async throws -> (median: Double, max: Double) {
        var times: [Double] = []
        for _ in 0..<5 { times.append(try await milliseconds(body)) }
        times.sort()
        return (times[2], times[4])
    }

    @Test func collectingStaysWithinBudget() async throws {
        let source = ExtensionInventorySource()
        var contribution = InventoryContribution()
        let cold = try await milliseconds { contribution = try await source.collect() }
        for record in contribution.extensions.records {
            print("record \(record.layer) \(record.kind) \(record.bundleID) \(record.versionText ?? "-") \(record.state) signing=\(record.signing?.kind.rawValue ?? "-")")
        }
        print("limitations=\(contribution.limitations + contribution.retryableLimitations) gaps=\(contribution.extensions.incompleteGroups) \(contribution.extensions.incompletePaths)")
        let warm = try await measure { _ = try await source.collect() }
        print("extension source records=\(contribution.extensions.records.count) cold_ms=\(cold) warm_ms median=\(warm.median) max=\(warm.max)")
        #expect(contribution.limitations.isEmpty && contribution.retryableLimitations.isEmpty)
        #expect(cold < Self.budgetMilliseconds)
        #expect(warm.max < Self.budgetMilliseconds)
    }

    /// Vollscan aus App-Inventar und Erweiterungen gegen das App-Inventar allein, je nach einem Aufwärmlauf.
    @Test func scanOverheadStaysWithinBudget() async throws {
        let apps = AppInventorySource()
        let withExtensions = ScanCoordinator(sources: [apps, ExtensionInventorySource()])
        let appsOnly = ScanCoordinator(sources: [apps])
        let snapshot = try await withExtensions.scan()
        _ = try await appsOnly.scan()
        for record in snapshot.extensions {
            print("owner \(record.bundleID) -> \(record.owner.map { "\($0)" } ?? "-")")
        }
        let baseline = try await measure { _ = try await appsOnly.scan() }
        let combined = try await measure { _ = try await withExtensions.scan() }
        print("scan apps only median=\(baseline.median) max=\(baseline.max); with extensions median=\(combined.median) max=\(combined.max); overhead_ms median=\(combined.median - baseline.median)")
        #expect(snapshot.extensions.allSatisfy { $0.owner != nil })
        #expect(combined.median - baseline.median < Self.budgetMilliseconds)
    }
}
