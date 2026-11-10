import Foundation
import Testing
@testable import ManagerKit

/// Darstellung des Bereichs „Erweiterungen“ (TM-13.5, #391): Schichten, Bewertung, Filter, Zustandszeile, ruhiges Urteil
/// nur bei vollständiger Prüfung, Detail und Aktionen.
struct ExtensionPresentationTests {
    static let now = TestData.date.addingTimeInterval(600)
    static let calendar = TestData.utcCalendar

    static let kext = TestData.kernelExtensionRecord()
    static let filter = TestData.extensionRecord(owner: .app(path: "/Applications/Vendor.app", evidence: .bundleID))
    static let guardian = TestData.extensionRecord("com.vendor.guard", kind: .endpointSecurity, name: "Guard",
                                                   owner: .missing)
    static let camera = TestData.extensionRecord("com.vendor.cam", kind: .camera, name: "Cam", state: .waitingForUser)
    static let driver = TestData.extensionRecord("com.vendor.dock", kind: .driver, name: "Dock")
    static let plugin = TestData.pluginRecord()
    static let applePlugin = TestData.pluginRecord("/Library/Audio/Plug-Ins/HAL/Apple.driver",
                                                   signing: SigningInfo(kind: .apple))

    static func finding(_ record: ExtensionRecord, _ severity: RiskFinding.Severity, _ message: String = "Befund",
                        rule: RiskFinding.Rule = .privilegedExtension) -> RiskFinding {
        RiskFinding(rule: rule, severity: severity, recordID: record.id, message: message)
    }

    static func coverage(_ records: [ExtensionRecord], errors: [SourceError] = []) -> AreaCoverage {
        var snapshot = TestData.extensionSnapshot(records, errors: errors)
        snapshot.lastDeliveryBySource[.extensions] = TestData.date
        return AreaCoverage(area: .extensions, snapshot: snapshot)
    }

    static func presentation(
        _ records: [ExtensionRecord], findings: [RiskFinding] = [], accepted: Set<String> = [],
        filter: ExtensionFilter = .all, query: String = "", coverage: AreaCoverage? = nil
    ) -> ExtensionPresentation {
        ExtensionPresentation(records: records, findings: findings, acceptedIDs: accepted, filter: filter, query: query,
                              coverage: coverage ?? Self.coverage(records))
    }

    // MARK: Schichten und Bewertung

    @Test func applePluginsAreHiddenAndCounted() {
        let presentation = Self.presentation([Self.plugin, Self.applePlugin])
        #expect(presentation.all.map(\.id) == [Self.plugin.id])
        #expect(presentation.hiddenApplePlugins == 1)
        #expect(presentation.layers.last?.note == "1 Plug-in von Apple ausgeblendet")
    }

    @Test func layersRunFromKernelOutwardWithFindingsFirst() {
        let presentation = Self.presentation(
            [Self.plugin, Self.driver, Self.filter, Self.guardian, Self.kext],
            findings: [Self.finding(Self.guardian, .medium)]
        )
        #expect(presentation.layers.map(\.layer) == ExtensionLayer.allCases)
        #expect(presentation.layers.map { $0.rows.map(\.id) } == [
            [Self.kext.id], [Self.guardian.id, Self.filter.id], [Self.driver.id], [Self.plugin.id],
        ])
        #expect(presentation.layers.map(\.findingCount) == [0, 1, 0, 0])
    }

    @Test func ratingFollowsStrongestFindingUnlessAccepted() {
        let presentation = Self.presentation(
            [Self.kext, Self.filter, Self.guardian, Self.driver],
            findings: [Self.finding(Self.kext, .medium), Self.finding(Self.kext, .high, rule: .kernelExtension),
                       Self.finding(Self.filter, .low), Self.finding(Self.guardian, .medium)],
            accepted: [Self.guardian.id]
        )
        let ratings = Dictionary(uniqueKeysWithValues: presentation.all.map { ($0.id, $0.rating) })
        #expect(ratings[Self.kext.id] == .critical)
        #expect(ratings[Self.filter.id] == .notice)
        #expect(ratings[Self.guardian.id] == .accepted)
        #expect(ratings[Self.driver.id] == .some(nil))
        #expect(ExtensionRating.allCases.map(\.title) == ["kritisch", "auffällig", "Hinweis", "akzeptiert"])
    }

    @Test(arguments: [
        (ExtensionFilter.kernel, [kext.id]), (.systemExtension, [filter.id, camera.id]), (.driver, [driver.id]),
        (.servicePlugin, [plugin.id]), (.findings, [kext.id]),
    ])
    func filterSelectsLayerOrFindings(_ filter: ExtensionFilter, _ expected: [String]) {
        let presentation = Self.presentation([Self.kext, Self.filter, Self.camera, Self.driver, Self.plugin],
                                             findings: [Self.finding(Self.kext, .medium)], filter: filter)
        #expect(Set(presentation.rows.map(\.id)) == Set(expected))
        #expect(presentation.sections.allSatisfy { !$0.rows.isEmpty })
        #expect(presentation.layers.flatMap(\.rows).count == 5)
    }

    @Test(arguments: ["vendor kext", "COM.VENDOR.DOCK", "TEAMPLUG01", "Vendor"])
    func searchMatchesNameBundleTeamAndVendor(_ query: String) {
        let presentation = Self.presentation([Self.kext, Self.driver, Self.plugin, Self.filter], query: query)
        #expect(!presentation.rows.isEmpty)
        #expect(Self.presentation([Self.kext], query: "nichts davon").rows.isEmpty)
    }

    @Test func radarLabelIsShort() {
        let long = TestData.extensionRecord(name: "Ein sehr langer Name einer Erweiterung")
        let row = Self.presentation([long]).all[0]
        #expect(row.radarLabel.count <= ExtensionRow.maximumRadarLabelLength)
        #expect(row.radarLabel.hasSuffix("…"))
    }

    // MARK: Zustandszeile und ruhiges Urteil

    @Test func verdictCountsFindingsKernelWaitingAndAccepted() {
        let presentation = Self.presentation(
            [Self.kext, Self.filter, Self.guardian, Self.camera, Self.plugin, Self.applePlugin],
            findings: [Self.finding(Self.kext, .medium, rule: .kernelExtension), Self.finding(Self.guardian, .medium)],
            accepted: [Self.guardian.id]
        )
        let verdict = presentation.verdict(now: Self.now, calendar: Self.calendar)
        #expect(verdict.title == "5 Erweiterungen, 1 auffällig")
        #expect(verdict.level == .finding)
        #expect(verdict.items == [
            ExtensionVerdict.Item(text: "1 im Kern", tone: .finding),
            ExtensionVerdict.Item(text: "1 wartet auf Freigabe", tone: .info),
            ExtensionVerdict.Item(text: "1 akzeptiert", tone: .neutral),
        ])
        #expect(verdict.facts == "1 Plug-in von Apple ausgeblendet · Geprüft heute, 14:13")
    }

    @Test func criticalFindingRaisesTheLevel() {
        let presentation = Self.presentation([Self.kext], findings: [Self.finding(Self.kext, .high, rule: .kernelExtension)])
        #expect(presentation.verdict(now: Self.now, calendar: Self.calendar).level == .critical)
        #expect(presentation.verdict(now: Self.now, calendar: Self.calendar).title == "1 Erweiterung, 1 auffällig")
    }

    @Test func calmOnlyAfterACompleteCheck() {
        let complete = Self.presentation([Self.applePlugin])
        #expect(complete.isCalm)
        #expect(complete.verdict(now: Self.now, calendar: Self.calendar).title == "Keine fremden Erweiterungen")
        #expect(complete.verdict(now: Self.now, calendar: Self.calendar).items == [ExtensionVerdict.Item(text: "Kern frei", tone: .positive)])
        #expect(complete.calmChecks.last == "Audio- und Video-Plug-ins: nur von Apple")

        let failed = Self.coverage([], errors: [SourceError(source: .extensions, message: "systemextensionsctl fehlt")])
        let incomplete = Self.presentation([], coverage: failed)
        #expect(!incomplete.isCalm)
        #expect(incomplete.verdict(now: Self.now, calendar: Self.calendar).title == "Nicht vollständig geprüft")
        #expect(incomplete.verdict(now: Self.now, calendar: Self.calendar).items.isEmpty)
        #expect(incomplete.notice(now: Self.now, calendar: Self.calendar)?.contains("systemextensionsctl fehlt") == true)
        #expect(complete.notice(now: Self.now) == nil)
    }

    // MARK: Detail und Aktionen

    @Test func detailExplainsPermissionFindingsAndOrigin() throws {
        let presentation = Self.presentation([Self.kext], findings: [Self.finding(Self.kext, .medium, "Kext läuft im Kern")])
        let detail = presentation.detail(of: try #require(presentation.all.first))
        #expect(detail.subtitle == "Kernel-Erweiterung · ohne bekannte App")
        #expect(detail.permission == ExtensionKind.kernelExtension.permissionText)
        #expect(detail.findings == [ExtensionDetail.Finding(text: "Kext läuft im Kern.", tone: .finding)])
        #expect(detail.acceptance == .offered)
        #expect(detail.facts.map(\.title) == ["Hersteller", "Team-ID", "Bundle-ID", "Version", "Signatur",
                                              "Zugehörige App", "Erstmals gesehen", "Pfad"])
        #expect(detail.facts.first { $0.title == "Signatur" }?.value == "Developer ID, notarisiert")
        #expect(detail.facts.first { $0.title == "Pfad" }?.isCode == true)
    }

    @Test func acceptanceOnlyForFindingsAndShownWhenAccepted() throws {
        let notice = Self.presentation([Self.filter], findings: [Self.finding(Self.filter, .low)])
        #expect(notice.detail(of: try #require(notice.all.first)).acceptance == nil)
        #expect(notice.detail(of: try #require(notice.all.first)).findings.map(\.tone) == [.info])

        let accepted = Self.presentation([Self.guardian], findings: [Self.finding(Self.guardian, .medium)],
                                         accepted: [Self.guardian.id])
        let detail = accepted.detail(of: try #require(accepted.all.first))
        #expect(detail.acceptance == .accepted)
        #expect(detail.findings.map(\.tone) == [.neutral])
        #expect(detail.facts.first { $0.title == "Zugehörige App" }?.value == "fehlt")
    }

    @Test func actionsFollowTheKindAndNeverTrashSystemOrAppleCode() throws {
        let kernelSettings = try #require(ExtensionSettingsLinks.kernelExtensions)
        let systemSettings = try #require(ExtensionSettingsLinks.systemExtensions)
        let presentation = Self.presentation([Self.kext, Self.filter, Self.plugin, Self.applePlugin])
        let actions = Dictionary(uniqueKeysWithValues: presentation.all.map { ($0.id, presentation.detail(of: $0).actions) })
        #expect(actions[Self.kext.id] == [.openSettings(kernelSettings),
                                         .revealInFinder(Self.kext.path ?? "")])
        #expect(actions[Self.filter.id] == [.openSettings(systemSettings),
                                           .showApp(path: "/Applications/Vendor.app")])
        #expect(actions[Self.plugin.id] == [.revealInFinder(Self.plugin.path ?? ""), .moveToTrash])
        #expect(ExtensionDetail.actions(for: Self.applePlugin).contains(.moveToTrash) == false)
    }

    @Test func ownerNameIsSingleLine() {
        let owner = ExtensionOwnership.app(path: "/Applications/Böse\nApp.app", evidence: .teamID)
        #expect(owner.appName == "Böse App")
        #expect(ExtensionOwnership.missing.appName == nil)
    }
}
