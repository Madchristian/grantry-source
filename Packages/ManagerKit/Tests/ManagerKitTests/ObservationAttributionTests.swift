import Foundation
import Testing
@testable import ManagerKit

@Suite("Zuordnung zur Beobachtung")
struct ObservationAttributionTests {
    private let cursorSigning = SigningInfo(kind: .developerID, teamID: "VDXQ22DGB9", isNotarized: true)

    private var cursor: InstalledApp {
        TestData.installedApp("Cursor", bundleID: "com.todesktop.230313mzl4w4u92", signing: cursorSigning)
    }

    private func identity(_ bundleID: String?, path: String? = nil, name: String = "Tool", teamID: String? = nil) -> AppIdentity {
        AppIdentity(bundleID: bundleID, path: path, displayName: name,
                    signing: SigningInfo(kind: teamID == nil ? .unknown : .developerID, teamID: teamID), presence: .present)
    }

    private func agent(_ label: String, program: String, owner: AppIdentity? = nil, teamID: String? = nil) -> AutostartItem {
        var item = TestData.userAgent(label, plistPath: "/Users/test/Library/LaunchAgents/\(label).plist", program: program,
                                      signing: teamID.map { SigningInfo(kind: .developerID, teamID: $0) })
        item.owner = owner
        return item
    }

    @Test func appMatchingTheNameIsLikelyOthersAreUncertain() {
        let other = TestData.installedApp("Zoom", bundleID: "us.zoom.xos")
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [cursor, other])
        #expect(attribution.verdict(for: .installedApp(cursor)) == .likely("Name passt zu „Cursor“."))
        #expect(attribution.verdict(for: .installedApp(other)).isLikely == false)
        #expect(attribution.toolApps == [cursor])
    }

    @Test func onlyNewAppIsLikelyEvenWithoutNameMatch() {
        let attribution = ObservationAttribution(observationName: "Mein Agent", newApps: [cursor])
        #expect(attribution.verdict(for: .installedApp(cursor)) == .likely("Einzige neue App während der Beobachtung."))
    }

    @Test func furtherAppOfTheSameTeamIsLikely() {
        let helperApp = TestData.installedApp("Updater", bundleID: "com.other.updater", signing: cursorSigning)
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [cursor, helperApp])
        #expect(attribution.verdict(for: .installedApp(helperApp)) == .likely("Gleiches Team wie „Cursor“ (VDXQ22DGB9)."))
    }

    @Test func grantOfTheToolAppIsLikely() {
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [cursor])
        let grant = TestData.grant("kTCCServiceAccessibility", client: identity(cursor.bundleID), scope: .system)
        #expect(attribution.verdict(for: .grant(grant)) == .likely("Gehört zu „Cursor“."))
    }

    @Test func grantOfAHelperInsideTheAppIsLikely() {
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [cursor])
        let helperPath = cursor.path + "/Contents/Frameworks/Helper.app"
        let grant = TestData.grant(client: identity(nil, path: helperPath))
        #expect(attribution.verdict(for: .grant(grant)) == .likely("Liegt in „Cursor“."))
    }

    @Test func autostartItemWithBundlePrefixSupportFolderOrTeamIsLikely() {
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [cursor])
        let prefixed = agent("com.todesktop.230313mzl4w4u92.ShipIt", program: "/usr/local/bin/shipit")
        #expect(attribution.verdict(for: .autostartItem(prefixed)) == .likely("Bundle-ID beginnt wie die von „Cursor“."))

        let support = agent("de.example.sync", program: "/Users/test/Library/Application Support/Cursor/bin/sync")
        #expect(attribution.verdict(for: .autostartItem(support))
            == .likely("Programm liegt im Support-Ordner von „Cursor“."))

        let sameTeam = agent("io.example.daemon", program: "/usr/local/bin/daemon", teamID: "VDXQ22DGB9")
        #expect(attribution.verdict(for: .autostartItem(sameTeam)) == .likely("Gleiches Team wie „Cursor“ (VDXQ22DGB9)."))
    }

    @Test func sameVendorPrefixIsLikelyButAppleIsNot() {
        let claude = TestData.installedApp("Claude", bundleID: "com.anthropic.claudefordesktop")
        let attribution = ObservationAttribution(observationName: "Claude Desktop", newApps: [claude])
        let updater = agent("com.anthropic.updater", program: "/usr/local/bin/updater")
        #expect(attribution.verdict(for: .autostartItem(updater))
            == .likely("Gleicher Hersteller wie „Claude“ (com.anthropic)."))

        let apple = TestData.installedApp("Pages", bundleID: "com.apple.iWork.Pages")
        let appleAttribution = ObservationAttribution(observationName: "Pages", newApps: [apple])
        let appleAgent = agent("com.apple.unrelated", program: "/usr/libexec/unrelated")
        #expect(appleAttribution.verdict(for: .autostartItem(appleAgent)).isLikely == false)
    }

    /// Kommandozeilenwerkzeuge bringen keine App mit – dann zählt der Name.
    @Test func withoutAppTheNameDecides() {
        let attribution = ObservationAttribution(observationName: "Claude Code", newApps: [])
        let agent = agent("com.example.claude-updater", program: "/Users/test/.claude/local/updater")
        #expect(attribution.verdict(for: .autostartItem(agent)) == .likely("Name passt zu „Claude Code“."))
        // „Code“ ist zu allgemein und ordnet nichts zu.
        let vscode = self.agent("com.microsoft.vscode.updater", program: "/usr/local/bin/code-updater")
        #expect(attribution.verdict(for: .autostartItem(vscode)).isLikely == false)
    }

    @Test func unrelatedEntriesAreUncertainWithReason() {
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [cursor])
        let terminal = TestData.grant("kTCCServiceAccessibility", client: identity("com.apple.Terminal", name: "Terminal"))
        #expect(attribution.verdict(for: .grant(terminal)) == .uncertain(ObservationAttribution.noRelation))
        let check = TestData.securityCheck(TestData.firewallOff, state: .critical)
        #expect(attribution.verdict(for: .securityCheck(check)) == .uncertain(ObservationAttribution.unknownSubject))
    }

    /// Ganze Wörter statt Teilzeichenketten: „Ice“ trifft nicht „service“, „Ray“ nicht „Library“.
    @Test func nameMatchesWholeWordsOnly() {
        let attribution = ObservationAttribution(observationName: "Ice", newApps: [])
        let office = agent("com.microsoft.office.licensingservice", program: "/Library/Application Support/x/service")
        #expect(attribution.verdict(for: .autostartItem(office)).isLikely == false)
        let ice = agent("com.jordanbaird.ice.helper", program: "/usr/local/bin/ice-helper")
        #expect(attribution.verdict(for: .autostartItem(ice)).isLikely)
    }

    /// Mit einer App des Tools zählt der Name allein nicht – nur die Beziehung zur App.
    @Test func nameRuleOnlyAppliesWithoutToolApp() {
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [cursor])
        let unrelated = agent("org.other.cursor-theme", program: "/usr/local/bin/theme")
        #expect(attribution.verdict(for: .autostartItem(unrelated)) == .uncertain(ObservationAttribution.noRelation))
    }

    /// Ein nebenbei installiertes Apple-Programm wird nie zur App des Tools.
    @Test func onlyNewAppSignedByAppleStaysUncertain() {
        let xcode = TestData.installedApp("Xcode", bundleID: "com.apple.dt.Xcode", origin: .appStore,
                                          signing: SigningInfo(kind: .apple))
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [xcode])
        #expect(attribution.verdict(for: .installedApp(xcode)).isLikely == false)
        #expect(attribution.toolApps.isEmpty)
    }

    /// ToDesktop-Apps teilen das Präfix `com.todesktop` – kein Beleg für denselben Hersteller.
    @Test func toDesktopPrefixIsNoVendorEvidence() {
        let attribution = ObservationAttribution(observationName: "Cursor", newApps: [cursor])
        let otherApp = agent("com.todesktop.99999otherapp.helper", program: "/usr/local/bin/other")
        #expect(attribution.verdict(for: .autostartItem(otherApp)).isLikely == false)
    }

    @Test func nameTokensIgnoreGenericWordsAndShortParts() {
        #expect(ObservationName("Claude Desktop App").tokens == ["claude"])
        #expect(ObservationName("VS Code").tokens.isEmpty)
        #expect(!ObservationName("  ").matches(any: ["anything"]))
    }
}
