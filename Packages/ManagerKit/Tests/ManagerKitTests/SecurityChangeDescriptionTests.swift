import Foundation
import Testing
@testable import ManagerKit

@Suite struct SecurityChangeDescriptionTests {
    private func describe(_ before: SecurityCheck, _ after: SecurityCheck) -> ChangeDescription {
        ChangeDescription(ChangeEvent(kind: .modified, before: .securityCheck(before), after: .securityCheck(after), detectedAt: TestData.date))
    }

    @Test func stealthModeOff() {
        let text = describe(TestData.securityCheck(TestData.firewallOn, state: .good), TestData.securityCheck(TestData.stealthOff, state: .warning))
        #expect(text == ChangeDescription(title: "Sicherheit verschlechtert", body: "Tarnmodus ausgeschaltet."))
    }

    @Test func firewallOnAgain() {
        let text = describe(TestData.securityCheck(TestData.firewallOff, state: .critical), TestData.securityCheck(TestData.firewallOn, state: .good))
        #expect(text == ChangeDescription(title: "Sicherheit verbessert", body: "Firewall eingeschaltet, Tarnmodus eingeschaltet."))
    }

    @Test func xprotectUpdated() {
        let text = describe(TestData.securityCheck(.xprotect(version: "5362", installedAt: TestData.date), state: .good),
                            TestData.securityCheck(.xprotect(version: "5363", installedAt: TestData.date), state: .good))
        #expect(text == ChangeDescription(title: "Sicherheitsstatus geändert", body: "XProtect aktualisiert auf 5363."))
    }

    @Test func pendingUpdateAgedToCritical() {
        let facts = SecurityFacts.pendingUpdates(updates: [TestData.update("A")], lastCheck: TestData.date)
        let text = describe(TestData.securityCheck(facts, state: .warning), TestData.securityCheck(facts, state: .critical))
        #expect(text == ChangeDescription(title: "Sicherheit verschlechtert", body: "Ausstehende Updates: Hinweis → kritisch."))
    }

    @Test func newAndInstalledPendingUpdates() {
        let macOS = TestData.update("MSU_UPDATE_27.0.1")
        let before = TestData.securityCheck(.pendingUpdates(updates: [macOS], lastCheck: TestData.date), state: .warning)
        let after = TestData.securityCheck(.pendingUpdates(updates: [
            PendingUpdate(identifier: "ProVideoFormats", displayName: "Pro Video-Formate", displayVersion: "3.2", firstSeenAt: TestData.date),
        ], lastCheck: TestData.date), state: .warning)
        #expect(describe(before, after).body
            == "Update verfügbar: Pro Video-Formate 3.2, Update nicht mehr ausstehend: macOS 27.0.1.")
    }

    @Test func versionIsNotRepeatedInTitle() {
        let update = PendingUpdate(identifier: "x", displayName: "macOS\u{00A0}27.0.1", displayVersion: "27.0.1", firstSeenAt: TestData.date)
        #expect(update.displayTitle == "macOS\u{00A0}27.0.1")
    }

    @Test func automaticUpdateKeyDisabled() {
        let text = describe(TestData.securityCheck(.automaticUpdates(disabled: []), state: .good),
                            TestData.securityCheck(.automaticUpdates(disabled: [.criticalUpdateInstall]), state: .critical))
        #expect(text.body == "Sicherheitsmaßnahmen installieren ausgeschaltet.")
    }

    @Test func mdmEnrollment() {
        let text = describe(TestData.securityCheck(.mdmEnrollment(enrolled: false, viaDEP: false), state: .good),
                            TestData.securityCheck(.mdmEnrollment(enrolled: true, viaDEP: false), state: .good))
        #expect(text == ChangeDescription(title: "Geräteverwaltung geändert", body: "Mac bei einer Geräteverwaltung (MDM) angemeldet."))
    }

    @Test func recoveryFromUnknownWithoutFacts() {
        let text = describe(SecurityCheck.failed(.gatekeeper, detail: "x"), TestData.securityCheck(.gatekeeper(enabled: true), state: .good))
        #expect(text == ChangeDescription(title: "Sicherheitsstatus geändert", body: "Gatekeeper geändert."))
    }

    @Test func addedAndRemoved() {
        let check = TestData.securityCheck(TestData.firewallOn, state: .good)
        #expect(ChangeDescription(ChangeEvent(kind: .added, before: nil, after: .securityCheck(check), detectedAt: TestData.date))
            == ChangeDescription(title: "Neue Sicherheitsprüfung", body: "Firewall: in Ordnung."))
        #expect(ChangeDescription(ChangeEvent(kind: .removed, before: .securityCheck(check), after: nil, detectedAt: TestData.date))
            == ChangeDescription(title: "Sicherheitsprüfung entfernt", body: "Firewall."))
    }
}
