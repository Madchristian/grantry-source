import Foundation
import Testing
@testable import ManagerKit

@Suite struct AutostartPresentationTests {
    @Test func statusBadgesShowEnabledStateAndKnownLoadState() {
        var item = TestData.item("x")
        #expect(item.statusBadges == [.enabled, .loaded])
        item.isEnabled = false
        item.isLoaded = false
        #expect(item.statusBadges == [.disabled, .notLoaded])
        item.isLoaded = nil
        #expect(item.statusBadges == [.disabled])
    }

    @Test func statusTitlesAndTones() {
        #expect(AutostartStatus.enabled.title == "aktiv" && AutostartStatus.enabled.tone == .positive)
        #expect(AutostartStatus.disabled.title == "deaktiviert" && AutostartStatus.disabled.tone == .neutral)
        #expect(AutostartStatus.loaded.title == "geladen")
        #expect(AutostartStatus.notLoaded.title == "nicht geladen")
        #expect(AutostartDomain.user.displayName == "Benutzer")
        #expect(AutostartDomain.system.displayName == "System")
    }

    @Test func onlyEntriesManagedBySystemSettingsLinkToLoginItems() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        #expect(ActionAvailability.Reason.managedBySystemSettings.settingsURL == url)
        #expect(ActionAvailability.Reason.appleComponent.settingsURL == nil)
        #expect(ActionAvailability.Reason.nonAquaSession.settingsURL == nil)
        let btm = TestData.item("y", kind: .loginItem, source: .btm)
        guard case .readOnly(let reason) = ActionPolicy().availability(for: btm) else {
            Issue.record("BTM-Eintrag sollte schreibgeschützt sein")
            return
        }
        #expect(reason.settingsURL == url)
    }

    @Test func outcomeTextsForAutostartActions() {
        let item = TestData.item("com.vendor.agent")
        #expect(ActionOutcomePresentation.setEnabled(item, false, outcome: .done).text == "„com.vendor.agent“ wurde deaktiviert.")
        #expect(ActionOutcomePresentation.setEnabled(item, true, outcome: .done).text == "„com.vendor.agent“ wurde aktiviert.")
        let removed = ActionOutcomePresentation.remove(item, outcome: .done)
        #expect(removed.text == "„com.vendor.agent“ wurde entfernt. Wiederherstellen ist im Verlauf möglich.")
        #expect(removed.tone == .positive)
        #expect(ActionOutcomePresentation.remove(item, outcome: .failed("kaputt")).text == "kaputt")
    }
}
