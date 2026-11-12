import Foundation
import Testing
@testable import ManagerKit

/// Zeile der App-Liste im Lagebild (LB-2.5, #542): Kurztext „Entwickler · Größe · zuletzt benutzt“ wie im Entwurf
/// LB-2.1 und „Mit Befund“ wie die Kachel „Auffällig“ (Befund mittel oder hoch).
@Suite struct AppListRowTextTests {
    private let now = TestData.date
    private let calendar = TestData.utcCalendar
    private let chrome = TestData.installedApp(
        "Google Chrome", bundleID: "com.google.Chrome",
        signing: SigningInfo(kind: .developerID, teamID: "EQHXZ8M8AV", isNotarized: true, developerName: "Google LLC")
    )
    private let store = TestData.installedApp("Notizblock", bundleID: "com.example.notes", origin: .appStore)

    private func row(_ app: InstalledApp, details: AppUsageDetails = AppUsageDetails(),
                     severity: RiskFinding.Severity? = nil) -> InstalledAppRow {
        AppInventoryPresenter.rows([app], details: [app.id: details], severity: { _ in severity }, query: "",
                                   filter: AppListFilter(), now: now, calendar: calendar)[0]
    }

    @Test func listDetailNamesDeveloperSizeAndLastUse() {
        let known = row(chrome, details: AppUsageDetails(size: 1_000, lastUsed: now - 3 * TestData.day))
        #expect(known.listDetail == "Google LLC · " + AppTexts.formattedSize(1_000) + " · vor 3 Tagen")
        #expect(row(chrome, details: AppUsageDetails(size: nil, lastUsed: now)).listDetail
            == "Google LLC · heute benutzt")
        #expect(row(chrome, details: AppUsageDetails(size: nil, lastUsed: now - TestData.day)).listDetail
            == "Google LLC · gestern")
    }

    @Test func listDetailFallsBackToTheOriginWithoutDeveloper() {
        #expect(row(store).listDetail == "App Store")
    }

    @Test func flaggedMeansMediumOrHighLikeTheTile() {
        #expect(row(chrome, severity: .high).isFlagged)
        #expect(row(chrome, severity: .medium).isFlagged)
        #expect(!row(chrome, severity: .low).isFlagged)
        #expect(!row(chrome).isFlagged)
    }
}
