import Foundation
import Testing
@testable import ManagerKit

@Suite struct SecurityCheckTests {
    @Test func idIsKindRawValueAndSourceIsSecurityPosture() {
        let check = TestData.securityCheck(TestData.firewallOn, state: .good)
        #expect(check.id == "firewall")
        #expect(check.source == .securityPosture)
    }

    @Test func stateChangeIsSignificant() {
        let good = TestData.securityCheck(TestData.firewallOn, state: .good)
        let warning = TestData.securityCheck(TestData.stealthOff, state: .warning)
        #expect(good.hasSignificantChanges(comparedTo: warning))
    }

    @Test func xprotectInstallDateIsNotSignificantButVersionIs() {
        let old = TestData.securityCheck(.xprotect(version: "5363", installedAt: TestData.date), state: .good)
        let sameVersionLater = TestData.securityCheck(.xprotect(version: "5363", installedAt: TestData.date + 86_400), state: .good)
        let newVersion = TestData.securityCheck(.xprotect(version: "5364", installedAt: TestData.date), state: .good)
        #expect(!old.hasSignificantChanges(comparedTo: sameVersionLater))
        #expect(old.hasSignificantChanges(comparedTo: newVersion))
    }

    @Test func pendingUpdatesCompareIdentifiersOnly() {
        let a = TestData.securityCheck(.pendingUpdates(updates: [TestData.update("A")], lastCheck: TestData.date), state: .warning)
        let aLater = TestData.securityCheck(
            .pendingUpdates(updates: [TestData.update("A", firstSeenAt: TestData.date - 100)], lastCheck: TestData.date + 3_600),
            state: .warning
        )
        let ab = TestData.securityCheck(
            .pendingUpdates(updates: [TestData.update("A"), TestData.update("B")], lastCheck: TestData.date), state: .warning
        )
        #expect(!a.hasSignificantChanges(comparedTo: aLater))
        #expect(a.hasSignificantChanges(comparedTo: ab))
    }

    @Test func failedCheckComparesWithItsLastKnownState() {
        let good = TestData.securityCheck(TestData.firewallOn, state: .good)
        var failed = SecurityCheck.failed(.firewall, detail: "Zeitüberschreitung")
        failed.facts = TestData.firewallOn
        failed.lastKnownState = .good
        let critical = TestData.securityCheck(TestData.firewallOff, state: .critical)
        #expect(failed.state == .unknown)
        #expect(failed.effectiveState == .good)
        #expect(!good.hasSignificantChanges(comparedTo: failed))
        #expect(failed.hasSignificantChanges(comparedTo: critical))
    }

    @Test(arguments: [
        (SecurityState.good, SecurityState.warning, true), (.good, .critical, true), (.warning, .critical, true),
        (.warning, .good, false), (.critical, .warning, false), (.good, .good, false),
        (.good, .unknown, false), (.unknown, .critical, false),
    ])
    func deterioration(from old: SecurityState, to new: SecurityState, expected: Bool) {
        #expect(new.isDeterioration(from: old) == expected)
    }

    @Test func worstStateOrdersUnknownBetweenGoodAndWarning() {
        #expect([SecurityState.good, .unknown].max(by: { $0.displayRank < $1.displayRank }) == .unknown)
        #expect([SecurityState.unknown, .warning].max(by: { $0.displayRank < $1.displayRank }) == .warning)
    }

    @Test func snapshotWithoutSecurityChecksDecodesFromOldJSON() throws {
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceCamera")])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "securityChecks")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.securityChecks.isEmpty)
        #expect(decoded.grants == snapshot.grants)
    }

    @Test func snapshotRoundTripsSecurityChecks() throws {
        var snapshot = TestData.snapshot()
        snapshot.securityChecks = [
            TestData.securityCheck(TestData.firewallOn, state: .good),
            TestData.securityCheck(.automaticUpdates(disabled: [.automaticDownload]), state: .warning),
            .failed(.sip, detail: "csrutil fehlt"),
        ]
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    /// Gespeicherte Prüfungen, deren Fakten nicht zur Art passen, werden abgelehnt statt still übernommen.
    @Test func decodingRejectsFactsOfAnotherKind() throws {
        let check = TestData.securityCheck(TestData.firewallOn, state: .good)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(check)) as? [String: Any])
        json["kind"] = SecurityCheckKind.sip.rawValue
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SecurityCheck.self, from: data) }
    }

    @Test func settingFactsOfAnotherKindTraps() async {
        await #expect(processExitsWith: .failure) {
            var check = SecurityCheck.failed(.sip, detail: "x")
            check.facts = .gatekeeper(enabled: true)
        }
    }

    @Test func equivalenceConsidersSecurityChecks() {
        var a = TestData.snapshot()
        a.securityChecks = [TestData.securityCheck(TestData.firewallOn, state: .good)]
        var b = a
        #expect(a.isEquivalent(to: b))
        b.securityChecks = [TestData.securityCheck(TestData.stealthOff, state: .warning)]
        #expect(!a.isEquivalent(to: b))
    }

    @Test func failedSourceCarriesSecurityChecksForward() {
        var previous = TestData.snapshot()
        previous.securityChecks = [TestData.securityCheck(TestData.firewallOn, state: .good)]
        let current = TestData.snapshot(errors: [SourceError(source: .securityPosture, message: "kaputt")])
        #expect(current.carryingForwardRecords(ofFailedSourcesFrom: previous).securityChecks == previous.securityChecks)
    }

    @Test func derivedBaselineIncludesSecurityPosture() {
        let snapshot = Snapshot(
            takenAt: TestData.date, grants: [], autostartItems: [],
            securityChecks: [TestData.securityCheck(TestData.firewallOn, state: .good)], sourceErrors: []
        )
        #expect(snapshot.baselineSources == [.securityPosture])
    }
}
