import Testing
import ManagerKit

/// Detailzeile im Kopf der Gruppe „Updates“ der Einstellungen (LB-5.2, #553; Entwurf LB-5.1).
@Suite struct UpdateSettingsDetailTests {
    @Test func detailFollowsConsentCheckAndOutcome() {
        #expect(UpdateTexts.settingsDetail(isEnabled: false, isChecking: false, availableVersion: nil,
                                           installedVersion: "2026.11.11") == "aus")
        #expect(UpdateTexts.settingsDetail(isEnabled: true, isChecking: true, availableVersion: "2026.11.14",
                                           installedVersion: "2026.11.11") == "Prüfung läuft")
        #expect(UpdateTexts.settingsDetail(isEnabled: true, isChecking: false, availableVersion: "2026.11.14",
                                           installedVersion: "2026.11.11") == "Grantry 2026.11.14 verfügbar")
        #expect(UpdateTexts.settingsDetail(isEnabled: true, isChecking: false, availableVersion: nil,
                                           installedVersion: "2026.11.11") == "täglich · Grantry 2026.11.11")
    }

    /// Eine Prüfung „Jetzt prüfen“ geht auch ohne Zustimmung; ihr Ergebnis zählt dann trotzdem.
    @Test func manualCheckWithoutConsentStillShowsAvailableUpdate() {
        #expect(UpdateTexts.settingsDetail(isEnabled: false, isChecking: true, availableVersion: nil,
                                           installedVersion: "2026.11.11") == "Prüfung läuft")
        #expect(UpdateTexts.settingsDetail(isEnabled: false, isChecking: false, availableVersion: "2026.11.14",
                                           installedVersion: "2026.11.11") == "Grantry 2026.11.14 verfügbar")
    }
}
