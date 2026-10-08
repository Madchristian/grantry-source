import Foundation
import Testing
@testable import ManagerKit

/// Nach dem Entfernen verschwinden die in den Papierkorb gelegten Apps sofort aus der Anzeige – bis ein danach
/// begonnener Scan sie bestätigt.
@Suite struct TrashedAppsTests {
    private static let zoom = TestData.installedApp("Zoom")
    private static let slack = TestData.installedApp("Slack", bundleID: "com.tinyspeck.slackmacgap")
    private static let removedAt = TestData.date.addingTimeInterval(60)

    private static func report(_ entries: [(LeftoverCandidate, RemovalReport.Result)]) -> RemovalReport {
        RemovalReport(entries: entries.map { RemovalReport.Entry(subject: .file($0.0), result: $0.1) })
    }

    private static func bundle(of app: InstalledApp) -> LeftoverCandidate {
        LeftoverCandidate(path: app.path, kind: .appBundle, confidence: .safe)
    }

    private static func trashedZoom() -> TrashedApps {
        var trashed = TrashedApps()
        trashed.record(report([
            (bundle(of: zoom), .done),
            (LeftoverCandidate(path: "/Users/test/Library/Caches/us.zoom.xos", kind: .caches, confidence: .safe), .done),
        ]), at: removedAt)
        return trashed
    }

    @Test func hidesTrashedAppFromSnapshotTakenBeforeTheRemoval() {
        let snapshot = TestData.appSnapshot([Self.zoom, Self.slack], at: TestData.date)
        let shown = Self.trashedZoom().applied(to: snapshot)
        #expect(shown.installedApps == [Self.slack])
        #expect(shown.takenAt == snapshot.takenAt)
    }

    /// Ein Scan, der nach der Entfernung begann, gilt: Ist die App wieder da (erneut installiert), erscheint sie.
    @Test func snapshotTakenAfterTheRemovalIsShownUnchanged() {
        let later = TestData.appSnapshot([Self.zoom, Self.slack], at: Self.removedAt.addingTimeInterval(1))
        #expect(Self.trashedZoom().applied(to: later) == later)
    }

    @Test func failedOrSkippedBundlesStayVisible() {
        var trashed = TrashedApps()
        trashed.record(Self.report([(Self.bundle(of: Self.zoom), .failed("Finder")),
                                    (Self.bundle(of: Self.slack), .skipped("läuft"))]), at: Self.removedAt)
        #expect(trashed.isEmpty)
        let snapshot = TestData.appSnapshot([Self.zoom, Self.slack], at: TestData.date)
        #expect(trashed.applied(to: snapshot) == snapshot)
    }

    @Test func doneWithWarningCountsAsTrashed() {
        var trashed = TrashedApps()
        trashed.record(Self.report([(Self.bundle(of: Self.zoom), .doneWithWarning("Beleg fehlt"))]), at: Self.removedAt)
        #expect(!trashed.isEmpty)
    }

    /// Ein nach der Entfernung begonnener Scan ersetzt den Vermerk; ältere lassen ihn bestehen.
    @Test func pruneForgetsRemovalsConfirmedByALaterSnapshot() {
        var trashed = Self.trashedZoom()
        trashed.prune(confirmedBy: TestData.appSnapshot([], at: TestData.date))
        #expect(!trashed.isEmpty)
        trashed.prune(confirmedBy: TestData.appSnapshot([], at: Self.removedAt.addingTimeInterval(1)))
        #expect(trashed.isEmpty)
    }

    @Test func presentationInputAppliesTrashedApps() throws {
        let state = MonitoringState(snapshot: TestData.appSnapshot([Self.zoom, Self.slack], at: TestData.date))
        let input = try #require(PresentationInput(state: state, recentAdditions: [], trashedApps: Self.trashedZoom()))
        #expect(input.snapshot.installedApps == [Self.slack])
        #expect(input.make(now: Self.removedAt).installedApps == [Self.slack])
    }
}
