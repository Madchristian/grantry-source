import Foundation
import Testing
@testable import ManagerKit

@Suite struct InstalledAppTests {
    @Test func idIsPathAndSourceIsApps() {
        let app = TestData.installedApp()
        #expect(app.id == "/Applications/Zoom.app")
        #expect(app.source == .apps)
        #expect(app.identity == AppIdentity(
            bundleID: "us.zoom.xos", path: "/Applications/Zoom.app", displayName: "Zoom",
            signing: TestData.developerSigning, presence: .present
        ))
    }

    @Test func versionChangesAreSignificant() {
        let app = TestData.installedApp()
        #expect(app.hasSignificantChanges(comparedTo: TestData.installedApp(version: "6.1")))
        #expect(app.hasSignificantChanges(comparedTo: TestData.installedApp(build: "601")))
        #expect(!app.hasSignificantChanges(comparedTo: TestData.installedApp()))
    }

    @Test func teamIDChangeCountsOnlyWhenBothAreKnown() {
        let teamA = TestData.installedApp()
        let teamB = TestData.installedApp(signing: SigningInfo(kind: .developerID, teamID: "TEAMB67890", isNotarized: true))
        let noTeam = TestData.installedApp(signing: SigningInfo(kind: .developerID, teamID: nil, isNotarized: true))
        #expect(teamA.hasSignificantChanges(comparedTo: teamB))
        #expect(!teamA.hasSignificantChanges(comparedTo: noTeam))
    }

    /// Eine Zeitüberschreitung der Signaturprüfung (`.unknown`) darf kein Ereignis auslösen.
    @Test func signingKindChangeIgnoresUnknown() {
        let developer = TestData.installedApp()
        #expect(developer.hasSignificantChanges(comparedTo: TestData.installedApp(signing: SigningInfo(kind: .adHoc))))
        #expect(!developer.hasSignificantChanges(comparedTo: TestData.installedApp(signing: .unknown)))
    }

    @Test func architectureChangeIgnoresUnknown() {
        let intel = TestData.installedApp(architecture: .intel)
        #expect(intel.hasSignificantChanges(comparedTo: TestData.installedApp(architecture: .universal)))
        #expect(!intel.hasSignificantChanges(comparedTo: TestData.installedApp(architecture: .unknown)))
    }

    @Test func teamIDChangeRecordIsNotSignificant() {
        var changed = TestData.installedApp()
        changed.teamIDChange = TeamIDChange(previousTeamID: "OLDTEAM123", detectedAt: TestData.date)
        #expect(!TestData.installedApp().hasSignificantChanges(comparedTo: changed))
    }

    @Test(arguments: [
        ("6.0", "600", "6.0 (600)"), ("6.0", "6.0", "6.0"), ("6.0", nil, "6.0"), (nil, "600", "600"),
    ] as [(String?, String?, String)])
    func versionText(short: String?, build: String?, expected: String) {
        #expect(TestData.installedApp(version: short, build: build).versionText == expected)
    }

    @Test func versionTextIsNilWithoutVersions() {
        #expect(TestData.installedApp(version: nil, build: nil).versionText == nil)
    }
}

@Suite struct SnapshotInstalledAppsTests {
    @Test func olderSnapshotsDecodeWithoutApps() throws {
        let snapshot = TestData.snapshot(grants: [TestData.grant()])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json["installedApps"] = nil
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.installedApps.isEmpty)
        #expect(decoded.grants == snapshot.grants)
    }

    @Test func appsRoundTripAndDeriveTheirBaseline() throws {
        let app = TestData.installedApp(origin: .homebrew(cask: "zoom"))
        let snapshot = Snapshot(takenAt: TestData.date, grants: [], autostartItems: [], installedApps: [app], sourceErrors: [])
        #expect(snapshot.baselineSources == [.apps])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func equivalenceComparesApps() {
        let before = TestData.appSnapshot([TestData.installedApp()])
        #expect(before.isEquivalent(to: TestData.appSnapshot([TestData.installedApp()])))
        #expect(!before.isEquivalent(to: TestData.appSnapshot([TestData.installedApp(version: "6.1")])))
        #expect(!before.isEquivalent(to: TestData.appSnapshot([])))
    }

    @Test func failedAppSourceCarriesAppsForward() {
        let previous = TestData.appSnapshot([TestData.installedApp()])
        let current = TestData.appSnapshot([], errors: [SourceError(source: .apps, message: "nicht lesbar")])
        #expect(current.carryingForwardRecords(ofFailedSourcesFrom: previous).installedApps == previous.installedApps)
    }

    /// Der Entwicklername allein (etwa neu aus dem Zertifikat gelesen) ist kein Ereignis.
    @Test func developerNameAloneIsNotSignificant() {
        let named = TestData.installedApp(signing: SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true,
                                                              developerName: "Zoom Video Communications, Inc."))
        #expect(!TestData.installedApp().hasSignificantChanges(comparedTo: named))
    }
}
