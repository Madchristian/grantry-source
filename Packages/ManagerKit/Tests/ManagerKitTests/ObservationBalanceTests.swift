import Foundation
import Testing
@testable import ManagerKit

@Suite("Bilanz einer Beobachtung")
struct ObservationBalanceTests {
    private let later = TestData.date.addingTimeInterval(600)

    @Test func groupsAddedModifiedRemovedAndSecurityChanges() {
        let kept = TestData.item("com.vendor.kept")
        var disabled = kept
        disabled.isEnabled = false
        let firewallOn = TestData.securityCheck(TestData.firewallOn, state: .good)
        let firewallOff = TestData.securityCheck(TestData.firewallOff, state: .critical)
        let baselineSources = TestData.appSources.union([.securityPosture])
        let baseline = Snapshot(
            takenAt: TestData.date, grants: [], autostartItems: [kept, TestData.item("com.vendor.gone")],
            securityChecks: [firewallOn], installedApps: [], sourceErrors: [], baselineSources: baselineSources
        )
        let cursor = TestData.installedApp("Cursor", bundleID: "com.todesktop.cursor")
        let final = Snapshot(
            takenAt: later, grants: [TestData.grant(client: TestData.app("com.todesktop.cursor"))],
            autostartItems: [disabled, TestData.item("com.todesktop.cursor.helper")], securityChecks: [firewallOff],
            installedApps: [cursor], sourceErrors: [], baselineSources: baselineSources
        )

        let balance = ObservationBalance(baseline: baseline, final: final)
        let groups = balance.groups
        #expect(groups[.newGrants]?.count == 1)
        #expect(groups[.newAutostartItems]?.map(\.subject.recordID) == [TestData.item("com.todesktop.cursor.helper").id])
        #expect(groups[.newApps]?.map(\.subject.recordID) == [cursor.id])
        #expect(groups[.modified]?.map(\.subject.recordID) == [kept.id])
        #expect(groups[.removed]?.map(\.subject.recordID) == [TestData.item("com.vendor.gone").id])
        #expect(groups[.securityChanges]?.count == 1)
        #expect(balance.addedCount == 3)
        #expect(balance.failedSources.isEmpty && balance.firstDeliveredSources.isEmpty)
    }

    /// Baseline-Regel des `SnapshotDiffer`: Eine Quelle, die erst während der Beobachtung liefert, erzeugt keine
    /// „neu“-Einträge – die Bilanz nennt sie.
    @Test func sourceDeliveringFirstDuringObservationIsBaseline() {
        let baseline = TestData.snapshot(baseline: [.tccSystem, .launchd])
        let final = TestData.snapshot(items: [TestData.item("com.vendor.task", kind: .backgroundTask, source: .btm)],
                                      baseline: [.tccSystem, .launchd, .btm], at: later)
        let balance = ObservationBalance(baseline: baseline, final: final)
        #expect(balance.events.isEmpty)
        #expect(balance.firstDeliveredSources == [.btm])
    }

    @Test func failedSourcesAtStartOrEndAreNamed() {
        let baseline = TestData.snapshot(errors: [SourceError(source: .btm, message: "Helper fehlt")])
        let final = TestData.snapshot(errors: [SourceError(source: .tccSystem, message: "kein Zugriff")], at: later)
        #expect(ObservationBalance(baseline: baseline, final: final).failedSources == [.btm, .tccSystem])
    }

    @Test func presentationOrdersSectionsAndAttributesOnlyAdditions() {
        let cursor = TestData.installedApp("Cursor", bundleID: "com.todesktop.cursor")
        let kept = TestData.item("com.vendor.kept")
        var disabled = kept
        disabled.isEnabled = false
        let baseline = TestData.appSnapshot([], items: [kept])
        let final = TestData.appSnapshot([cursor], items: [disabled], at: later)
        let balance = ObservationBalance(baseline: baseline, final: final)
        let presentation = ObservationBalancePresentation(
            balance: balance, attribution: ObservationAttribution(observationName: "Cursor", newApps: [cursor])
        )
        #expect(presentation.sections.map(\.group) == [.newApps, .modified])
        #expect(presentation.sections[0].rows[0].verdict?.isLikely == true)
        #expect(presentation.sections[1].rows[0].verdict == nil)
        #expect(presentation.summary == "1 neu, 1 geändert, 0 entfernt")
    }
}
