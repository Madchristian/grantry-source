import Testing
import Foundation
@testable import ManagerKit

@Suite struct SnapshotCarryForwardTests {
    let later = TestData.date.addingTimeInterval(60)
    let btmItem = TestData.item("com.docker.docker", kind: .loginItem, source: .btm)
    let launchdItem = TestData.item("com.example.agent", source: .launchd)
    let btmFailure = SourceError(source: .btm, message: "helper offline")

    @Test func copiesOnlyRecordsOfFailedSources() {
        let grant = TestData.grant()
        let previous = TestData.snapshot(grants: [grant], items: [btmItem, launchdItem])
        let current = TestData.snapshot(items: [launchdItem], errors: [btmFailure], at: later)
        let carried = current.carryingForwardRecords(ofFailedSourcesFrom: previous)
        #expect(carried.grants.isEmpty)
        #expect(carried.autostartItems == [launchdItem, btmItem])
        #expect(carried.sourceErrors == [btmFailure])
        #expect(carried.takenAt == later)
    }

    @Test func carriesGrantsPerTCCDatabase() {
        let userGrant = TestData.grant(scope: .user)
        let systemGrant = TestData.grant(scope: .system)
        let previous = TestData.snapshot(grants: [userGrant, systemGrant])
        let failure = SourceError(source: .tccUser, message: "kein Zugriff")
        let current = TestData.snapshot(grants: [systemGrant], errors: [failure], at: later)
        let carried = current.carryingForwardRecords(ofFailedSourcesFrom: previous)
        #expect(carried.grants == [systemGrant, userGrant])
    }

    @Test func carryingForwardTwiceIsIdempotent() {
        let previous = TestData.snapshot(grants: [TestData.grant()], items: [btmItem, launchdItem])
        let current = TestData.snapshot(items: [launchdItem], errors: [btmFailure], at: later)
        let once = current.carryingForwardRecords(ofFailedSourcesFrom: previous)
        #expect(once.carryingForwardRecords(ofFailedSourcesFrom: previous) == once)
    }

    @Test func nilPreviousLeavesSnapshotUnchanged() {
        let current = TestData.snapshot(items: [launchdItem], errors: [btmFailure], at: later)
        #expect(current.carryingForwardRecords(ofFailedSourcesFrom: nil) == current)
    }

    @Test func noFailedSourcesLeavesSnapshotUnchanged() {
        let previous = TestData.snapshot(items: [btmItem])
        let current = TestData.snapshot(items: [launchdItem], at: later)
        #expect(current.carryingForwardRecords(ofFailedSourcesFrom: previous) == current)
    }

    @Test func recoveringSourceProducesNoFalseAdditions() {
        let differ = SnapshotDiffer()
        let s1 = TestData.snapshot(items: [btmItem, launchdItem])
        let s2 = TestData.snapshot(items: [launchdItem], errors: [btmFailure], at: later)
        let carried = s2.carryingForwardRecords(ofFailedSourcesFrom: s1)
        #expect(differ.diff(from: s1, to: carried).isEmpty)

        let s3 = TestData.snapshot(items: [btmItem, launchdItem], at: later.addingTimeInterval(60))
        #expect(differ.diff(from: carried, to: s3).isEmpty)
    }

    @Test func carryingForwardPreservesBaselineSources() {
        let previous = TestData.snapshot(items: [btmItem, launchdItem], baseline: [.launchd, .btm])
        let current = TestData.snapshot(items: [launchdItem], errors: [btmFailure], baseline: [.launchd, .btm], at: later)
        #expect(current.carryingForwardRecords(ofFailedSourcesFrom: previous).baselineSources == [.launchd, .btm])
    }
}

@Suite struct SnapshotBaselineCodingTests {
    @Test func roundTripsBaselineSources() throws {
        let snapshot = TestData.snapshot(items: [TestData.item()], baseline: [.launchd, .btm])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func legacySnapshotDerivesBaselineFromRecordSources() throws {
        let grant = TestData.grant(scope: .system)
        let item = TestData.item("com.docker.docker", kind: .loginItem, source: .btm)
        let snapshot = TestData.snapshot(grants: [grant], items: [item], baseline: [])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "baselineSources")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.baselineSources == [grant.source, .btm])
        #expect(decoded.grants == [grant])
        #expect(decoded.autostartItems == [item])
    }

    @Test func initWithoutBaselineDerivesItFromRecordSources() {
        let snapshot = Snapshot(takenAt: TestData.date, grants: [TestData.grant()], autostartItems: [], sourceErrors: [])
        #expect(snapshot.baselineSources == [.tccUser])
    }
}

@Suite struct SnapshotEquivalenceTests {
    let later = TestData.date.addingTimeInterval(60)
    let camera = TestData.grant("kTCCServiceCamera")
    let microphone = TestData.grant("kTCCServiceMicrophone")
    let agent = TestData.item("com.example.agent")
    let helper = TestData.item("com.example.helper")
    let btmFailure = SourceError(source: .btm, message: "helper offline")
    let tccFailure = SourceError(source: .tccUser, message: "kein Zugriff")

    @Test func reorderedRecordsAndErrorsAreEquivalent() {
        let a = TestData.snapshot(grants: [camera, microphone], items: [agent, helper], errors: [btmFailure, tccFailure])
        let b = TestData.snapshot(grants: [microphone, camera], items: [helper, agent], errors: [tccFailure, btmFailure], at: later)
        #expect(a.isEquivalent(to: b))
    }

    @Test func insignificantChangesAreEquivalent() {
        var touched = camera
        touched.lastModified = later
        #expect(TestData.snapshot(grants: [camera]).isEquivalent(to: TestData.snapshot(grants: [touched], at: later)))
    }

    @Test func changedAuthValueIsNotEquivalent() {
        let denied = TestData.grant(authValue: .denied)
        #expect(!TestData.snapshot(grants: [camera]).isEquivalent(to: TestData.snapshot(grants: [denied], at: later)))
    }

    @Test func differentIDSetsAreNotEquivalent() {
        #expect(!TestData.snapshot(items: [agent]).isEquivalent(to: TestData.snapshot(items: [agent, helper])))
        #expect(!TestData.snapshot(grants: [camera]).isEquivalent(to: TestData.snapshot()))
    }

    @Test func differentFailedSourcesAreNotEquivalent() {
        #expect(!TestData.snapshot(errors: [btmFailure]).isEquivalent(to: TestData.snapshot()))
    }

    @Test func differentErrorMessagesOfSameSourceAreEquivalent() {
        let other = SourceError(source: .btm, message: "Zeitüberschreitung")
        #expect(TestData.snapshot(errors: [btmFailure]).isEquivalent(to: TestData.snapshot(errors: [other])))
    }

    /// Eine neu hinzugekommene Baseline-Quelle muss gespeichert werden, sonst gälte ihre nächste Lieferung erneut als Baseline.
    @Test func differentBaselineSourcesAreNotEquivalent() {
        #expect(!TestData.snapshot(baseline: [.launchd]).isEquivalent(to: TestData.snapshot(baseline: [.launchd, .btm])))
    }
}
