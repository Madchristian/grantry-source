import Foundation
import Testing
@testable import ManagerKit

@Suite struct RiskRulesTests {
    let unsignedApp = TestData.app("com.shady", signing: SigningInfo(kind: .unsigned))
    let adHocApp = TestData.app("com.adhoc", signing: SigningInfo(kind: .adHoc))
    let appleApp = TestData.app("com.apple.x", signing: SigningInfo(kind: .apple))
    let nonNotarized = TestData.app("com.dev", signing: SigningInfo(kind: .developerID, teamID: "T", isNotarized: false))

    @Test func unsignedClientRuleFlagsUnsignedAndAdHoc() {
        let snapshot = TestData.snapshot(
            grants: [TestData.grant(client: unsignedApp), TestData.grant(client: appleApp)],
            items: [TestData.item("x", owner: adHocApp)]
        )
        let findings = UnsignedClientRule().evaluate(snapshot)
        #expect(Set(findings.map(\.recordID)) == ["user|kTCCServiceCamera|com.shady", "launchAgent|user|x"])
        #expect(findings.allSatisfy { $0.rule == .unsignedClient })
        #expect(findings.allSatisfy { $0.severity == .high })
    }

    @Test func unsignedClientRuleIgnoresDeniedGrants() {
        let snapshot = TestData.snapshot(grants: [TestData.grant(client: unsignedApp, authValue: .denied)])
        let findings = UnsignedClientRule().evaluate(snapshot)
        #expect(findings.isEmpty)
    }

    @Test func unsignedClientRuleFlagsLimitedGrants() {
        let snapshot = TestData.snapshot(grants: [TestData.grant(client: unsignedApp, authValue: .limited)])
        let findings = UnsignedClientRule().evaluate(snapshot)
        #expect(findings.map(\.recordID) == ["user|kTCCServiceCamera|com.shady"])
    }

    @Test func unsignedClientRuleUsesAppOwnerWordingForAutostartItems() {
        let snapshot = TestData.snapshot(items: [TestData.item("x", owner: adHocApp)])
        let findings = UnsignedClientRule().evaluate(snapshot)
        #expect(findings.map(\.message) == ["Zugehörige App von x ist nicht signiert"])
    }

    @Test func orphanRuleFlagsMissingAppsAndPrograms() {
        let gone = TestData.app("com.gone", presence: .missing)
        let snapshot = TestData.snapshot(
            grants: [TestData.grant(client: gone), TestData.grant()],
            items: [TestData.item("y", programPresence: .missing), TestData.item("z")]
        )
        let findings = OrphanRule().evaluate(snapshot)
        #expect(Set(findings.map(\.recordID)) == ["user|kTCCServiceCamera|com.gone", "launchAgent|user|y"])
        #expect(findings.allSatisfy { $0.rule == .orphan })
        #expect(findings.allSatisfy { $0.severity == .medium })
    }

    @Test func orphanRuleDoesNotFlagItemsWithUnknownProgram() {
        // program == nil heißt "Quelle kennt den Pfad nicht", nicht "Programm fehlt".
        let snapshot = TestData.snapshot(items: [TestData.item("noProgram", programPresence: .unknown, hasProgram: false)])
        let findings = OrphanRule().evaluate(snapshot)
        #expect(findings.isEmpty)
    }

    /// Unbekannte Existenz (z. B. root-only-Verzeichnis, Bundle-ID ohne Launch-Services-Eintrag) ist kein Beleg
    /// für eine fehlende App.
    @Test func orphanRuleIgnoresUnknownPresence() {
        let unknownClient = TestData.app("com.microsoft.wdav.epsext", presence: .unknown)
        let snapshot = TestData.snapshot(
            grants: [TestData.grant(client: unknownClient)],
            items: [TestData.item("com.wazuh.agent", programPresence: .unknown)]
        )
        #expect(OrphanRule().evaluate(snapshot).isEmpty)
    }

    @Test func sensitiveNonNotarizedRuleSkipsClientsWithUnknownPresence() {
        let unknownClient = TestData.app("com.unknown", signing: .unknown, presence: .unknown)
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: unknownClient)])
        #expect(SensitiveNonNotarizedRule().evaluate(snapshot).isEmpty)
    }

    @Test func orphanRuleFlagsProbablyMissingClients() {
        let gone = TestData.app("ai.openclaw.mac", signing: .unknown, presence: .probablyMissing)
        let snapshot = TestData.snapshot(grants: [
            TestData.grant("kTCCServiceScreenCapture", client: gone),
            TestData.grant("kTCCServiceAccessibility", client: gone, authValue: .denied),
        ])
        let findings = OrphanRule().evaluate(snapshot)
        #expect(findings.map(\.recordID) == ["user|kTCCServiceScreenCapture|ai.openclaw.mac"])
        #expect(findings.map(\.severity) == [.medium])
        #expect(findings.map(\.message) == ["ai.openclaw.mac ist vermutlich nicht mehr installiert"])
    }

    @Test func sensitiveNonNotarizedRuleSkipsProbablyMissingClients() {
        let gone = TestData.app("ai.openclaw.mac", signing: .unknown, presence: .probablyMissing)
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: gone)])
        #expect(SensitiveNonNotarizedRule().evaluate(snapshot).isEmpty)
    }

    /// Eine verweigerte Berechtigung einer gelöschten App ist eine Altlast, kein Risiko.
    @Test func orphanRuleIgnoresDeniedGrants() {
        let gone = TestData.app("com.gone", presence: .missing)
        let snapshot = TestData.snapshot(grants: [
            TestData.grant(client: gone, authValue: .denied),
            TestData.grant("kTCCServiceMicrophone", client: gone, authValue: .limited),
        ])
        #expect(OrphanRule().evaluate(snapshot).map(\.recordID) == ["user|kTCCServiceMicrophone|com.gone"])
    }

    /// Apple-Komponenten, die Launch Services nicht findet (z. B. `com.apple.screensharing.agent`), sind nie verwaist.
    @Test func orphanRuleSkipsAppleComponents() {
        let appleByID = TestData.app("com.apple.screensharing.agent", signing: .unknown, presence: .missing)
        let appleByPath = AppIdentity(bundleID: nil, path: "/usr/libexec/gone", displayName: "gone", signing: .unknown,
                                      presence: .missing)
        let snapshot = TestData.snapshot(
            grants: [TestData.grant(client: appleByID), TestData.grant(client: appleByPath)],
            items: [TestData.item("com.apple.gone", programPresence: .missing)]
        )
        #expect(OrphanRule().evaluate(snapshot).isEmpty)
    }

    @Test func sensitiveNonNotarizedRuleSkipsAppleComponents() {
        let underXcode = AppIdentity(bundleID: nil, path: "/Applications/Xcode.app/Contents/Developer/usr/bin/tool",
                                     displayName: "tool", signing: .unknown, presence: .present)
        let appleID = TestData.app("com.apple.CoreSimulator.SimulatorTrampoline", signing: .unknown)
        let snapshot = TestData.snapshot(grants: [
            TestData.grant("kTCCServiceAccessibility", client: underXcode),
            TestData.grant("kTCCServiceAccessibility", client: appleID),
        ])
        #expect(SensitiveNonNotarizedRule().evaluate(snapshot).isEmpty)
    }

    @Test func sensitiveNonNotarizedRuleOnlyForSensitiveAllowedGrants() {
        let snapshot = TestData.snapshot(grants: [
            TestData.grant("kTCCServiceAccessibility", client: nonNotarized),
            TestData.grant("kTCCServiceAccessibility", client: nonNotarized, authValue: .denied, scope: .system),
            TestData.grant("kTCCServiceCamera", client: nonNotarized),
            TestData.grant("kTCCServiceScreenCapture", client: appleApp),
        ])
        let findings = SensitiveNonNotarizedRule().evaluate(snapshot)
        #expect(findings.map(\.recordID) == ["user|kTCCServiceAccessibility|com.dev"])
        #expect(findings.allSatisfy { $0.severity == .low })
        #expect(findings.first?.message.contains("nicht als notarisiert bestätigt") == true)
    }

    @Test func sensitiveNonNotarizedRuleDoesNotDoubleFlagUnsignedOrAdHoc() {
        // UnsignedClientRule deckt unsignierte/ad-hoc-signierte Apps bereits ab.
        let snapshot = TestData.snapshot(grants: [
            TestData.grant("kTCCServiceAccessibility", client: unsignedApp),
            TestData.grant("kTCCServiceAccessibility", client: adHocApp),
        ])
        let findings = SensitiveNonNotarizedRule().evaluate(snapshot)
        #expect(findings.isEmpty)
    }

    @Test func sensitiveNonNotarizedRuleCountsLimitedAsGranted() {
        let snapshot = TestData.snapshot(grants: [
            TestData.grant("kTCCServiceAccessibility", client: nonNotarized, authValue: .limited),
        ])
        let findings = SensitiveNonNotarizedRule().evaluate(snapshot)
        #expect(findings.map(\.recordID) == ["user|kTCCServiceAccessibility|com.dev"])
    }

    @Test func sensitiveNonNotarizedRuleSkipsClientsThatNoLongerExist() {
        // Eine fehlende App hat oft .unknown-Signing; ohne Existenz-Filter würde sie doppelt
        // (Orphan + SensitiveNonNotarized) markiert.
        let missingApp = TestData.app("com.missing", signing: SigningInfo(kind: .unknown), presence: .missing)
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: missingApp)])
        #expect(SensitiveNonNotarizedRule().evaluate(snapshot).isEmpty)
        #expect(OrphanRule().evaluate(snapshot).map(\.recordID) == ["user|kTCCServiceAccessibility|com.missing"])
    }

    @Test func sensitiveNonNotarizedRuleFlagsUnknownSigningOnExistingApp() {
        let unknownApp = TestData.app("com.unknown", signing: SigningInfo(kind: .unknown))
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: unknownApp)])
        let findings = SensitiveNonNotarizedRule().evaluate(snapshot)
        #expect(findings.map(\.recordID) == ["user|kTCCServiceAccessibility|com.unknown"])
    }

    /// Lokale Entwickler-Builds (Apple Development) werden nie notarisiert – ein Hinweis darauf wäre reines Rauschen.
    @Test func sensitiveNonNotarizedRuleIgnoresDevelopmentBuilds() {
        let devBuild = TestData.app("de.cstrube.Grantry", signing: SigningInfo(kind: .development, teamID: "73SP5UXC3Q"))
        let snapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: devBuild)])
        #expect(SensitiveNonNotarizedRule().evaluate(snapshot).isEmpty)
    }

    @Test func sensitiveNonNotarizedRuleIgnoresAppStoreAndNotarizedDeveloperID() {
        let appStoreApp = TestData.app("com.appstore", signing: SigningInfo(kind: .appStore, isNotarized: false))
        let notarizedDevApp = TestData.app("com.notarized", signing: SigningInfo(kind: .developerID, teamID: "T", isNotarized: true))
        let snapshot = TestData.snapshot(grants: [
            TestData.grant("kTCCServiceAccessibility", client: appStoreApp),
            TestData.grant("kTCCServiceAccessibility", client: notarizedDevApp),
        ])
        #expect(SensitiveNonNotarizedRule().evaluate(snapshot).isEmpty)
    }

    @Test func evaluatorCombinesAllRules() {
        let unsignedSnapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: unsignedApp)])
        let unsignedRules = RiskEvaluator.standard.evaluate(unsignedSnapshot).map(\.rule)
        #expect(Set(unsignedRules) == [.unsignedClient])

        let nonNotarizedSnapshot = TestData.snapshot(grants: [TestData.grant("kTCCServiceAccessibility", client: nonNotarized)])
        let nonNotarizedRules = RiskEvaluator.standard.evaluate(nonNotarizedSnapshot).map(\.rule)
        #expect(Set(nonNotarizedRules) == [.sensitiveNonNotarized])
    }

    @Test func evaluatorSortsBySeverityDescendingThenRecordID() {
        let gone = TestData.app("com.gone", presence: .missing)
        let snapshot = TestData.snapshot(grants: [
            TestData.grant("kTCCServiceAccessibility", client: nonNotarized),
            TestData.grant(client: gone),
            TestData.grant(client: unsignedApp),
        ])
        let findings = RiskEvaluator.standard.evaluate(snapshot)
        #expect(findings.map(\.severity) == [.high, .medium, .low])
        #expect(findings.map(\.rule) == [.unsignedClient, .orphan, .sensitiveNonNotarized])
    }

    @Test func evaluatorSortsTiesByRecordIDAscending() {
        let zApp = TestData.app("com.z.shady", signing: SigningInfo(kind: .unsigned))
        let aApp = TestData.app("com.a.shady", signing: SigningInfo(kind: .unsigned))
        let snapshot = TestData.snapshot(grants: [TestData.grant(client: zApp), TestData.grant(client: aApp)])
        let findings = RiskEvaluator.standard.evaluate(snapshot)
        #expect(findings.map(\.recordID) == ["user|kTCCServiceCamera|com.a.shady", "user|kTCCServiceCamera|com.z.shady"])
    }

    private struct StubRule: RiskRule {
        let findings: [RiskFinding]
        func evaluate(_ snapshot: Snapshot) -> [RiskFinding] { findings }
    }

    @Test func evaluatorSortsFinalTiesByRuleRawValueAscending() {
        let tied = [
            RiskFinding(rule: .sensitiveNonNotarized, severity: .high, recordID: "same", message: "b"),
            RiskFinding(rule: .unsignedClient, severity: .high, recordID: "same", message: "c"),
            RiskFinding(rule: .orphan, severity: .high, recordID: "same", message: "a"),
        ]
        let evaluator = RiskEvaluator(rules: [StubRule(findings: tied)])
        let sorted = evaluator.evaluate(TestData.snapshot())
        #expect(sorted.map(\.rule) == [.orphan, .sensitiveNonNotarized, .unsignedClient])
    }

    @Test func findingIdCombinesRuleAndRecordID() {
        let finding = RiskFinding(rule: .orphan, severity: .medium, recordID: "user|kTCCServiceCamera|com.gone", message: "x")
        #expect(finding.id == "orphan|user|kTCCServiceCamera|com.gone")
    }

    @Test func findingRoundTripsThroughJSON() throws {
        let finding = RiskFinding(
            rule: .sensitiveNonNotarized, severity: .low,
            recordID: "user|kTCCServiceAccessibility|com.dev", message: "x"
        )
        let data = try JSONEncoder().encode(finding)
        let decoded = try JSONDecoder().decode(RiskFinding.self, from: data)
        #expect(decoded == finding)
    }
}
