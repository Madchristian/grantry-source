import Foundation
import Testing
@testable import ManagerKit

@Suite struct AppChangeDescriptionTests {
    private func event(_ kind: ChangeEvent.Kind, before: InstalledApp?, after: InstalledApp?) -> ChangeEvent {
        ChangeEvent(kind: kind, before: before.map(ChangeSubject.installedApp), after: after.map(ChangeSubject.installedApp),
                    detectedAt: TestData.date)
    }

    @Test func installedAppNamesVersionAndOrigin() {
        let app = TestData.installedApp("darktable", bundleID: "org.darktable", version: "5.6.1", build: "5.6.1",
                                        origin: .homebrew(cask: "darktable"))
        #expect(ChangeDescription(event(.added, before: nil, after: app))
                == ChangeDescription(title: "App installiert", body: "darktable 5.6.1 (Homebrew)."))
    }

    @Test func removedApp() {
        #expect(ChangeDescription(event(.removed, before: TestData.installedApp(), after: nil))
                == ChangeDescription(title: "App entfernt", body: "Zoom 6.0 (600)."))
    }

    @Test func updatedAppListsTheVersion() {
        let description = ChangeDescription(event(.modified, before: TestData.installedApp(),
                                                  after: TestData.installedApp(version: "6.1", build: "610")))
        #expect(description == ChangeDescription(title: "App aktualisiert", body: "Zoom: Version 6.0 (600) → 6.1 (610)."))
    }

    @Test func teamChangeHasItsOwnTitleAndListsAllChanges() {
        let after = TestData.installedApp(version: "6.1", signing: SigningInfo(kind: .adHoc, teamID: "TEAMB67890"),
                                          architecture: .intel)
        let description = ChangeDescription(event(.modified, before: TestData.installedApp(), after: after))
        #expect(description.title == "Entwickler-Team einer App geändert")
        #expect(description.body == "Zoom: Version 6.0 (600) → 6.1 (600), Team-ID TEAMA12345 → TEAMB67890, "
                + "Signatur Developer ID → ad hoc, Architektur Universal → Intel.")
    }

    /// Review M3: Team A → ad hoc (ohne Team) → Team B ist ein Team-Wechsel – Vergleichsbasis ist die zuletzt bekannte
    /// Team-ID des Vorgängers.
    @Test func teamChangeAcrossASignatureWithoutTeam() {
        var before = TestData.installedApp(signing: SigningInfo(kind: .adHoc))
        before.lastKnownTeamID = "TEAMA12345"
        let after = TestData.installedApp(signing: SigningInfo(kind: .developerID, teamID: "TEAMB67890", isNotarized: true))
        let description = ChangeDescription(event(.modified, before: before, after: after))
        #expect(description.title == "Entwickler-Team einer App geändert")
        #expect(description.body == "Zoom: Team-ID TEAMA12345 → TEAMB67890, Signatur ad hoc → Developer ID.")
    }

    /// Dieselbe Team-ID wie vor der Zwischenstufe ist kein Wechsel.
    @Test func sameTeamAfterASignatureWithoutTeamIsNoTeamChange() {
        var before = TestData.installedApp(signing: SigningInfo(kind: .adHoc))
        before.lastKnownTeamID = "TEAMA12345"
        let description = ChangeDescription(event(.modified, before: before, after: TestData.installedApp()))
        #expect(description == ChangeDescription(title: "App geändert", body: "Zoom: Signatur ad hoc → Developer ID."))
    }

    @Test func signatureOnlyChangeIsAChangedApp() {
        let description = ChangeDescription(event(.modified, before: TestData.installedApp(),
                                                  after: TestData.installedApp(signing: SigningInfo(kind: .adHoc))))
        #expect(description == ChangeDescription(title: "App geändert", body: "Zoom: Signatur Developer ID → ad hoc."))
    }

    @Test func originDetailNamesCaskOrDeveloper() {
        #expect(TestData.installedApp(origin: .homebrew(cask: "zoom")).originDetail == "Homebrew (Cask zoom)")
        let google = SigningInfo(kind: .developerID, teamID: "EQHXZ8M8AV", isNotarized: true, developerName: "Google LLC")
        #expect(TestData.installedApp(signing: google).originDetail == "Direkt – Google LLC")
        #expect(TestData.installedApp().originDetail == "Direkt")
        #expect(TestData.installedApp(origin: .appStore).originDetail == "App Store")
        #expect(TestData.installedApp(origin: .webApp(browser: .safari)).originDetail == "Web-App (Safari)")
    }
}
