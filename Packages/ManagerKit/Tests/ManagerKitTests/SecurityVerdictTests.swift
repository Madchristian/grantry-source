import Foundation
import Testing
@testable import ManagerKit

/// Urteil der Lagezeile und Zählung des Panels „Schutz“ im Bereich Sicherheit (TM-16.2, #407).
@Suite struct SecurityVerdictTests {
    private let now = TestData.date

    /// Die zehn Prüfungen in Ordnung, die `replacements` an ihrer Stelle.
    private func overview(replacing replacements: [SecurityCheck] = []) -> SecurityOverview {
        let kinds = Set(replacements.map(\.kind))
        let checks = TestData.goodSecurityChecks().filter { !kinds.contains($0.kind) } + replacements
        return SecurityOverview.make(checks: checks, now: now)
    }

    private func evaluated(_ facts: SecurityFacts) -> SecurityCheck { TestData.evaluatedCheck(facts) }

    private func item(_ text: String, _ tone: PresentationTone) -> SystemVerdict.Item { .init(text: text, tone: tone) }

    @Test func allGoodIsProtected() {
        let overview = overview()
        let verdict = overview.verdict(helperState: .ready)
        #expect(verdict.level == .calm)
        #expect(verdict.title == "Geschützt")
        #expect(verdict.reason == "Alle 10 Prüfungen sind in Ordnung.")
        #expect(verdict.items == [item("FileVault an", .positive), item("Firewall an", .positive), item("SIP aktiv", .positive)])
        #expect(verdict.facts == "10 Prüfungen · Helper bereit")
        #expect(verdict.processFindings.isEmpty)
        #expect(overview.leadingCheckID == nil)
        #expect(overview.panelDetail == "10 von 10 in Ordnung" && overview.panelValue == "")
    }

    @Test func oneWarningIsOneOpenPoint() {
        let overview = overview(replacing: [evaluated(TestData.stealthOff)])
        let verdict = overview.verdict(helperState: .ready)
        #expect(verdict.level == .finding)
        #expect(verdict.title == "1 Punkt offen")
        #expect(verdict.reason == "Firewall an, Tarnmodus aus – der Mac antwortet auf Anfragen wie Ping.")
        #expect(verdict.items == [item("Tarnmodus aus", .warning), item("FileVault an", .positive), item("SIP aktiv", .positive)])
        #expect(overview.leadingCheckID == "firewall")
        #expect(overview.panelDetail == "9 von 10 in Ordnung" && overview.panelValue == "1 offen")
    }

    @Test func severalWarningsAreCounted() {
        let overview = overview(replacing: [evaluated(TestData.stealthOff), evaluated(.sharingServices(active: [.remoteLogin]))])
        let verdict = overview.verdict(helperState: .ready)
        #expect(verdict.level == .finding && verdict.title == "2 Punkte offen")
        #expect(verdict.items == [item("Tarnmodus aus", .warning), item("1 Freigabe aktiv", .warning),
                                  item("FileVault an", .positive)])
        #expect(overview.leadingCheckID == "firewall")
    }

    /// Ein kritischer Punkt steht im Titel, auch neben Hinweisen; Grund und aufgeklappte Zeile gehören zu ihm.
    @Test func singleCriticalNamesItInTheTitle() {
        let updates = [TestData.update("a", firstSeenAt: now - 5 * TestData.day), TestData.update("b", name: "Safari 27.1")]
        let overview = overview(replacing: [evaluated(.sip(.disabled)),
                                            evaluated(.pendingUpdates(updates: updates, lastCheck: now))])
        let verdict = overview.verdict(helperState: .ready)
        #expect(verdict.level == .critical)
        #expect(verdict.title == "Kritisch: SIP aus")
        #expect(verdict.reason == "Der Systemintegritätsschutz ist ausgeschaltet.")
        #expect(verdict.items == [item("SIP aus", .critical), item("2 Updates offen", .warning), item("FileVault an", .positive)])
        #expect(overview.leadingCheckID == "sip")
        #expect(overview.panelDetail == "8 von 10 in Ordnung" && overview.panelValue == "2 offen")
    }

    @Test func severalCriticalAreCountedInDisplayOrder() {
        let overview = overview(replacing: [evaluated(.gatekeeper(enabled: false)), evaluated(TestData.firewallOff)])
        let verdict = overview.verdict(helperState: .ready)
        #expect(verdict.level == .critical && verdict.title == "2 Punkte kritisch")
        #expect(verdict.reason == "Die Firewall ist ausgeschaltet.")
        #expect(verdict.items == [item("Firewall aus", .critical), item("Gatekeeper aus", .critical), item("FileVault an", .positive)])
        #expect(overview.leadingCheckID == "firewall")
    }

    @Test func moreThanThreePointsAreSummarized() {
        let overview = overview(replacing: [evaluated(.fileVault(.off)), evaluated(TestData.stealthOff),
                                            evaluated(.sip(.disabled)), evaluated(.gatekeeper(enabled: false))])
        let verdict = overview.verdict(helperState: .ready)
        #expect(verdict.title == "3 Punkte kritisch")
        #expect(verdict.items == [item("FileVault aus", .critical), item("SIP aus", .critical), item("2 weitere", .critical)])
    }

    /// Nicht prüfbar ist weder Entwarnung noch Befund: eigener Titel, neutraler Chip, kein Befund-Punkt.
    @Test func uncheckedOnlyIsNoAllClear() {
        let overview = overview(replacing: [.failed(.xprotect, detail: "keine Leserechte")])
        let verdict = overview.verdict(helperState: .ready)
        #expect(verdict.level == .calm)
        #expect(verdict.title == "1 Prüfung nicht möglich")
        #expect(verdict.reason == "XProtect konnte nicht geprüft werden, die übrigen Prüfungen sind in Ordnung.")
        #expect(verdict.items == [item("XProtect nicht prüfbar", .neutral), item("FileVault an", .positive),
                                  item("Firewall an", .positive)])
        #expect(overview.leadingCheckID == "xprotect")
        #expect(overview.panelDetail == "9 von 10 in Ordnung · 1 nicht prüfbar" && overview.panelValue == "")
    }

    @Test func severalUncheckedAreNamed() {
        let overview = overview(replacing: [.failed(.xprotect, detail: "x"), .failed(.gatekeeper, detail: "y")])
        let verdict = overview.verdict(helperState: .ready)
        #expect(verdict.title == "2 Prüfungen nicht möglich")
        #expect(verdict.reason == "Gatekeeper und XProtect konnten nicht geprüft werden, die übrigen Prüfungen sind in Ordnung.")
    }

    /// Christian, 08.11.2026: offen und nicht prüfbar getrennt zählen – keine falsche Entwarnung.
    @Test func openAndUncheckedAreCountedSeparately() {
        let overview = overview(replacing: [evaluated(TestData.firewallOff), .failed(.xprotect, detail: "keine Leserechte")])
        let verdict = overview.verdict(helperState: .notInstalled)
        #expect(verdict.title == "Kritisch: Firewall aus")
        #expect(verdict.items == [item("Firewall aus", .critical), item("XProtect nicht prüfbar", .neutral),
                                  item("FileVault an", .positive)])
        #expect(verdict.facts == "10 Prüfungen · Helper nicht bereit")
        #expect((overview.goodCount, overview.hintCount, overview.uncheckedCount) == (8, 1, 1))
        #expect(overview.panelDetail == "8 von 10 in Ordnung · 1 nicht prüfbar" && overview.panelValue == "1 offen")
    }

    @Test func factsWithoutKnownHelperNameOnlyTheChecks() {
        #expect(overview().verdict(helperState: nil).facts == "10 Prüfungen")
    }

    @Test(arguments: [
        (SecurityFacts.fileVault(.on), "FileVault an"), (.fileVault(.off), "FileVault aus"),
        (.fileVault(.encrypting), "FileVault verschlüsselt"), (.fileVault(.pendingRestart), "FileVault nach Neustart"),
        (TestData.firewallOn, "Firewall an"), (TestData.stealthOff, "Tarnmodus aus"), (TestData.firewallOff, "Firewall aus"),
        (.sip(.enabled), "SIP aktiv"), (.sip(.customConfiguration), "SIP teilweise"), (.sip(.disabled), "SIP aus"),
        (.gatekeeper(enabled: true), "Gatekeeper an"), (.gatekeeper(enabled: false), "Gatekeeper aus"),
        (.xprotect(version: "1", installedAt: TestData.date), "XProtect aktuell"),
        (.xprotect(version: "1", installedAt: TestData.date - 40 * TestData.day), "XProtect veraltet"),
        (.automaticUpdates(disabled: []), "Updates automatisch"),
        (.automaticUpdates(disabled: [.automaticDownload]), "Updates teils manuell"),
        (.automaticUpdates(disabled: [.criticalUpdateInstall]), "Automatische Updates aus"),
        (.pendingUpdates(updates: [], lastCheck: TestData.date), "Keine Updates offen"),
        (.pendingUpdates(updates: [], lastCheck: nil), "Updatesuche überfällig"),
        (.pendingUpdates(updates: [TestData.update("a")], lastCheck: TestData.date), "1 Update offen"),
        (.mdmEnrollment(enrolled: true, viaDEP: false), "MDM angemeldet"),
        (.mdmEnrollment(enrolled: false, viaDEP: false), "Kein MDM"),
        (.automaticLogin(enabled: true), "Automatische Anmeldung an"),
        (.automaticLogin(enabled: false), "Anmeldung mit Passwort"),
        (.sharingServices(active: []), "Freigaben aus"),
        (.sharingServices(active: [.screenSharing, .fileSharing]), "2 Freigaben aktiv"),
    ])
    func briefNamesTheState(facts: SecurityFacts, expected: String) {
        #expect(SecurityCheckPresentation(TestData.evaluatedCheck(facts), now: now).brief == expected)
    }

    @Test func uncheckedBriefNamesTheCheck() {
        #expect(SecurityCheckPresentation(.failed(.sip, detail: "x"), now: now).brief == "SIP nicht prüfbar")
        #expect(SecurityCheckPresentation(.failed(.pendingUpdates, detail: "x"), now: now).brief == "Updates nicht prüfbar")
    }

    /// Jede Prüfung hat ihr eigenes Symbol in der Zeile; den Zustand trägt der Chip.
    @Test func everyCheckHasItsOwnSymbol() {
        let symbols = SecurityCheckKind.allCases.map(\.systemImage)
        #expect(Set(symbols).count == SecurityCheckKind.allCases.count)
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(TestData.firewallOff), now: now)
        #expect(row.systemImage == SecurityCheckKind.firewall.systemImage && row.state == .critical)
    }
}
