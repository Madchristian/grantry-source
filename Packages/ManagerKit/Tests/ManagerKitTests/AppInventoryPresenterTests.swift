import Foundation
import Testing
@testable import ManagerKit

@Suite struct AppInventoryPresenterTests {
    private let app2 = TestData.installedApp("App 2", bundleID: "com.example.two", origin: .appStore, architecture: .appleSilicon)
    private let app10 = TestData.installedApp("app 10", bundleID: "com.example.ten", origin: .homebrew(cask: "ten"),
                                              architecture: .intel)
    private let chrome = TestData.installedApp(
        "Google Chrome", bundleID: "com.google.Chrome",
        signing: SigningInfo(kind: .developerID, teamID: "EQHXZ8M8AV", isNotarized: true, developerName: "Google LLC")
    )
    private let now = TestData.date
    private let calendar = TestData.utcCalendar

    private func rows(
        _ filter: AppListFilter = AppListFilter(), query: String = "", details: [String: AppUsageDetails] = [:],
        severities: [String: RiskFinding.Severity] = [:]
    ) -> [InstalledAppRow] {
        AppInventoryPresenter.rows([chrome, app10, app2], details: details, severity: { severities[$0] }, query: query,
                                   filter: filter, now: now, calendar: calendar)
    }

    private func names(
        _ filter: AppListFilter = AppListFilter(), query: String = "", details: [String: AppUsageDetails] = [:],
        severities: [String: RiskFinding.Severity] = [:]
    ) -> [String] {
        rows(filter, query: query, details: details, severities: severities).map(\.app.name)
    }

    // MARK: Sortierung

    @Test func sortsByNameNumericallyAndCaseInsensitively() {
        #expect(names() == ["App 2", "app 10", "Google Chrome"])
    }

    @Test func sortsBySizeAndLastUsedDescendingWithUnknownLast() {
        let details = [app2.id: AppUsageDetails(size: 10, lastUsed: now - TestData.day),
                       chrome.id: AppUsageDetails(size: 30, lastUsed: nil),
                       app10.id: AppUsageDetails(size: nil, lastUsed: now)]
        #expect(names(AppListFilter(sort: .size), details: details) == ["Google Chrome", "App 2", "app 10"])
        #expect(names(AppListFilter(sort: .lastUsed), details: details) == ["app 10", "App 2", "Google Chrome"])
    }

    @Test func unknownValuesFallBackToTheNameOrder() {
        #expect(names(AppListFilter(sort: .size)) == ["App 2", "app 10", "Google Chrome"])
        #expect(names(AppListFilter(sort: .lastUsed)) == ["App 2", "app 10", "Google Chrome"])
    }

    // MARK: Filter und Suche

    @Test func filtersByOriginArchitectureAndFlags() {
        #expect(names(AppListFilter(origin: .homebrew)) == ["app 10"])
        #expect(names(AppListFilter(origin: .appStore)) == ["App 2"])
        #expect(names(AppListFilter(origin: .direct)) == ["Google Chrome"])
        #expect(names(AppListFilter(origin: .webApp)).isEmpty)
        #expect(names(AppListFilter(architecture: .intel)) == ["app 10"])
        #expect(names(AppListFilter(architecture: .universal)) == ["Google Chrome"])
        #expect(names(AppListFilter(onlyFlagged: true), severities: [chrome.id: .low]) == ["Google Chrome"])
    }

    @Test func searchCoversNameBundleIDDeveloperAndCask() {
        #expect(names(query: "google llc") == ["Google Chrome"])
        #expect(names(query: "  com.example.two ") == ["App 2"])
        #expect(names(query: "ten") == ["app 10"])
        #expect(names(query: "nichts") == [])
    }

    @Test func filterIsActiveIgnoresTheSortOrder() {
        #expect(!AppListFilter(sort: .size).isActive)
        #expect(AppListFilter(architecture: .intel).isActive)
        #expect(AppListFilter(origin: .apple).isActive)
        #expect(AppListFilter(onlyFlagged: true).isActive)
    }

    // MARK: Zeilen

    @Test func rowTextsAreComputedOnce() {
        let row = rows(details: [app2.id: AppUsageDetails(size: 1_000, lastUsed: now)]).first { $0.app == app10 }!
        #expect(row.subtitle == "6.0 (600) · Homebrew · Intel")
        #expect(row.sizeText == "–")
        #expect(row.lastUsedText == "Zuletzt benutzt: unbekannt")
        let known = rows(details: [app2.id: AppUsageDetails(size: 1_000, lastUsed: now)]).first { $0.app == app2 }!
        #expect(known.sizeText == AppTexts.formattedSize(1_000))
        #expect(known.lastUsedText == "Zuletzt benutzt heute")
    }

    @Test func rowAccessibilityLabelNamesEverythingWithoutColor() {
        let row = rows(details: [chrome.id: AppUsageDetails(size: 1_000, lastUsed: now - TestData.day)],
                       severities: [chrome.id: .high]).first { $0.app == chrome }!
        #expect(row.accessibilityLabel == "Google Chrome, Version 6.0 (600), Direkt – Google LLC, Universal, Größe "
            + AppTexts.formattedSize(1_000) + ", Zuletzt benutzt gestern, Befund mit Schweregrad hoch")
    }

    @Test func lastUsedTexts() {
        #expect(AppTexts.lastUsed(now, now: now, calendar: calendar) == "Zuletzt benutzt heute")
        #expect(AppTexts.lastUsed(now - TestData.day, now: now, calendar: calendar) == "Zuletzt benutzt gestern")
        #expect(AppTexts.lastUsed(now - 3 * TestData.day, now: now, calendar: calendar) == "Zuletzt benutzt vor 3 Tagen")
        #expect(AppTexts.lastUsed(nil, now: now, calendar: calendar) == "Zuletzt benutzt: unbekannt")
    }

    @Test func filterTitles() {
        #expect(AppOriginFilter.allCases.map(\.title) == ["Alle Herkünfte", "App Store", "Homebrew", "Apple", "Web-Apps", "Direkt"])
        #expect(AppArchitectureFilter.allCases.map(\.title) == ["Alle Architekturen", "Apple Silicon", "Intel", "Universal"])
        #expect(AppSortOrder.allCases.map(\.title) == ["Name", "Größe", "Zuletzt benutzt"])
    }
}

@Suite struct InstalledAppDetailTests {
    private let now = TestData.date
    private let calendar = TestData.utcCalendar

    private func detail(
        _ app: InstalledApp, details: AppUsageDetails? = AppUsageDetails(), findings: [RiskFinding] = [],
        links: AppLinks = AppLinks(grants: [], autostartItems: [])
    ) -> InstalledAppDetail {
        InstalledAppDetail(app: app, details: details, findings: findings, links: links, now: now, calendar: calendar,
                           home: "/Users/test")
    }

    private func value(_ label: String, in detail: InstalledAppDetail) -> String? {
        detail.facts.first { $0.label == label }?.value
    }

    @Test func factsForADeveloperIDApp() {
        let app = TestData.installedApp(
            "Google Chrome", bundleID: "com.google.Chrome",
            signing: SigningInfo(kind: .developerID, teamID: "EQHXZ8M8AV", isNotarized: true, developerName: "Google LLC")
        )
        let result = detail(app, details: AppUsageDetails(size: 2_000, lastUsed: now - 3 * TestData.day))
        #expect(result.facts.map(\.label) == ["Version", "Herkunft", "Architektur", "Signatur", "Team", "Notarisierung",
                                              "Größe", "Zuletzt benutzt", "Bundle-ID"])
        #expect(value("Herkunft", in: result) == "Direkt – Google LLC")
        #expect(value("Signatur", in: result) == "Developer ID")
        #expect(value("Team", in: result) == "EQHXZ8M8AV")
        #expect(value("Notarisierung", in: result) == "Notarisiert")
        #expect(value("Größe", in: result) == AppTexts.formattedSize(2_000))
        #expect(value("Zuletzt benutzt", in: result) == "vor 3 Tagen")
        #expect(result.facts.first { $0.label == "Notarisierung" }?.accessibilityLabel == "Notarisierung: Notarisiert")
        #expect(result.signingNote == nil)
    }

    @Test func notarizationAndTeamForOtherSignatures() {
        let store = detail(TestData.installedApp(origin: .appStore, signing: SigningInfo(kind: .appStore, teamID: "T")))
        #expect(value("Notarisierung", in: store) == "Nicht nötig (von Apple geprüft)")
        let adHoc = detail(TestData.installedApp(signing: SigningInfo(kind: .adHoc)))
        #expect(value("Signatur", in: adHoc) == "Ad-hoc-signiert")
        #expect(value("Team", in: adHoc) == "Keins")
        #expect(value("Notarisierung", in: adHoc) == "Nicht notarisiert")
        #expect(adHoc.facts.first { $0.label == "Signatur" }?.tone == .warning)
        #expect(value("Notarisierung", in: detail(TestData.installedApp(signing: .unknown))) == "Unbekannt")
    }

    @Test func teamChangeIsNamed() {
        var app = TestData.installedApp()
        app.teamIDChange = TeamIDChange(previousTeamID: "OLDTEAM123", detectedAt: now)
        #expect(value("Team", in: detail(app)) == "TEAMA12345 (vorher OLDTEAM123)")
    }

    @Test func sizeWhileLoadingAndUnknown() {
        let app = TestData.installedApp()
        #expect(value("Größe", in: detail(app, details: nil)) == "Wird ermittelt …")
        #expect(value("Zuletzt benutzt", in: detail(app, details: nil)) == "Wird ermittelt …")
        #expect(value("Größe", in: detail(app)) == "Unbekannt")
        #expect(value("Zuletzt benutzt", in: detail(app)) == "Unbekannt")
    }

    @Test func signingNoteAndPathAndSymlink() {
        var app = TestData.installedApp(path: "/Users/test/Applications/Zoom.app")
        app.signingLimitation = .carriedForward(verifiedAt: now - 2 * TestData.day)
        app.symlinkTarget = "/Volumes/Apps/Zoom.app"
        let result = detail(app)
        #expect(result.signingNote == "Signatur nicht geprüft seit 2 Tagen")
        #expect(result.pathText == "~/Applications/Zoom.app")
        #expect(value("Verweist auf", in: result) == "/Volumes/Apps/Zoom.app")
    }

    @Test func versionAndBundleIDCanBeMissing() {
        let app = TestData.installedApp(bundleID: nil, version: nil, build: nil)
        let result = detail(app)
        #expect(value("Version", in: result) == "Unbekannt")
        #expect(value("Bundle-ID", in: result) == nil)
    }

    @Test func carriesFindingsAndLinks() {
        let app = TestData.installedApp()
        let grant = TestData.grant(client: app.identity)
        let item = TestData.item(owner: app.identity)
        let finding = RiskFinding(rule: .intelOnly, severity: .low, recordID: app.id, message: "Nur Intel")
        let result = detail(app, findings: [finding], links: AppLinks(grants: [grant], autostartItems: [item]))
        #expect(result.findings == [finding])
        #expect(result.grants == [grant])
        #expect(result.autostartItems == [item])
    }
}
