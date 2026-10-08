import Foundation
import Testing
@testable import ManagerKit

@Suite struct SecurityPresentationTests {
    private let now = TestData.date
    private let day = TestData.day

    @Test func stealthOffOffersOnlyTheStealthAction() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(TestData.stealthOff), now: now)
        #expect(row.id == "firewall" && row.kind == .firewall)
        #expect(row.title == "Firewall")
        #expect(row.statusText == "Hinweis" && row.tone == .warning)
        #expect(row.systemImage == PresentationTone.warning.systemImage)
        #expect(row.summary == "Firewall an, Tarnmodus aus – der Mac antwortet auf Anfragen wie Ping.")
        #expect(row.offers == [.action(.enableStealthMode, title: "Tarnmodus einschalten")])
        #expect(row.accessibilityLabel == "Firewall: Hinweis. Firewall an, Tarnmodus aus – der Mac antwortet auf Anfragen wie Ping.")
    }

    @Test func firewallOffOffersBothActions() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(TestData.firewallOff), now: now)
        #expect(row.tone == .critical && row.statusText == "Kritisch")
        #expect(row.offers == [.action(.enableFirewall, title: "Firewall einschalten"), .action(.enableStealthMode, title: "Tarnmodus einschalten")])
    }

    @Test func goodCheckOffersNothing() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(TestData.firewallOn), now: now)
        #expect(row.statusText == "In Ordnung" && row.tone == .positive)
        #expect(row.offers.isEmpty && row.explanation == nil && row.details.isEmpty)
    }

    @Test func sipOnlyExplainsRecovery() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(.sip(.disabled)), now: now)
        #expect(row.offers.isEmpty)
        #expect(row.explanation?.contains("Wiederherstellungsmodus") == true)
        #expect(SecurityCheckPresentation(TestData.evaluatedCheck(.sip(.enabled)), now: now).explanation == nil)
    }

    @Test func fileVaultOffLinksToSettings() throws {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(.fileVault(.off)), now: now)
        #expect(row.offers == [.link(title: "Datenschutz & Sicherheit öffnen", url: try #require(SecuritySettingsLinks.fileVault))])
        #expect(SecurityCheckPresentation(TestData.evaluatedCheck(.fileVault(.on)), now: now).offers.isEmpty)
    }

    @Test func gatekeeperOffOffersAction() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(.gatekeeper(enabled: false)), now: now)
        #expect(row.offers == [.action(.enableGatekeeper, title: "Gatekeeper einschalten")])
    }

    @Test func xprotectShowsVersionAgeAndAlwaysOffersUpdate() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(.xprotect(version: "5363", installedAt: now - 20 * day), now: now), now: now)
        #expect(row.tone == .warning)
        #expect(row.summary == "Version 5363, installiert vor 20 Tagen.")
        #expect(row.offers == [.action(.updateXProtect, title: "XProtect aktualisieren")])
    }

    @Test(arguments: [
        (0, SecurityCheckPresentation.DayPhrase.ago, "heute"), (1, .ago, "gestern"), (3, .ago, "vor 3 Tagen"), (-1, .ago, "heute"),
        (0, .since, "seit heute"), (1, .since, "seit gestern"), (14, .since, "seit 14 Tagen"),
    ])
    func dayText(days: Int, phrase: SecurityCheckPresentation.DayPhrase, expected: String) {
        #expect(SecurityCheckPresentation.dayText(days, phrase) == expected)
    }

    /// Anzeige und Ampel nutzen dasselbe Maß (`CalendarDays`): 14,5 Tage über 15 Tagesgrenzen sind „vor 15 Tagen“ und
    /// gelb, nie „vor 14 Tagen“ bei gelber Ampel.
    @Test func xprotectAgeMatchesThePolicyAtTheBoundary() throws {
        var policy = SecurityPolicy.standard
        policy.calendar = TestData.utcCalendar
        let installedAt = try Date("2026-09-15T20:00:00Z", strategy: .iso8601)
        let now = try Date("2026-09-30T08:00:00Z", strategy: .iso8601)
        let facts = SecurityFacts.xprotect(version: "5363", installedAt: installedAt)
        let check = SecurityCheck(kind: .xprotect, state: policy.evaluate(facts, now: now), facts: facts)
        let row = SecurityCheckPresentation(check, now: now, calendar: TestData.utcCalendar)
        #expect(row.tone == .warning)
        #expect(row.summary == "Version 5363, installiert vor 15 Tagen.")
    }

    @Test func yesterdayCountsCalendarDaysNotHours() throws {
        let installedAt = try Date("2026-09-29T23:00:00Z", strategy: .iso8601)
        let now = try Date("2026-09-30T01:00:00Z", strategy: .iso8601)
        let check = SecurityCheck(kind: .xprotect, state: .good, facts: .xprotect(version: "1", installedAt: installedAt))
        #expect(SecurityCheckPresentation(check, now: now, calendar: TestData.utcCalendar).summary == "Version 1, installiert gestern.")
    }

    @Test func pendingUpdatesListUpdatesWithAgeAndOfferSearchAndSettings() throws {
        let facts = SecurityFacts.pendingUpdates(updates: [
            PendingUpdate(identifier: "A", displayName: "macOS 27.0.1", displayVersion: "27.0.1", firstSeenAt: now - 2 * day),
        ], lastCheck: now)
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(facts, now: now), now: now)
        #expect(row.summary == "1 Update ausstehend.")
        #expect(row.details == ["macOS 27.0.1 – seit 2 Tagen", "Letzte Suche: heute"])
        #expect(row.offers == [.action(.checkForUpdates, title: "Jetzt suchen"),
                               .link(title: "Softwareupdate öffnen", url: try #require(SecuritySettingsLinks.softwareUpdate))])
    }

    @Test func noPendingUpdatesOffersOnlySearch() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(.pendingUpdates(updates: [], lastCheck: nil)), now: now)
        #expect(row.summary == "Keine Updates ausstehend.")
        #expect(row.details == ["Letzte Suche: noch nie"])
        #expect(row.offers == [.action(.checkForUpdates, title: "Jetzt suchen")])
    }

    @Test func automaticUpdatesListDisabledSwitches() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(.automaticUpdates(disabled: [.automaticDownload, .configDataInstall])), now: now)
        #expect(row.summary == "Ausgeschaltet: Neue Updates laden, Systemdateien installieren.")
        #expect(row.offers == [.action(.enableAutomaticUpdates, title: "Automatische Updates einschalten")])
    }

    @Test func enrolledMDMIsNeutral() {
        let row = SecurityCheckPresentation(TestData.evaluatedCheck(.mdmEnrollment(enrolled: true, viaDEP: false)), now: now)
        #expect(row.statusText == "Angemeldet" && row.tone == .neutral)
        #expect(row.systemImage == PresentationTone.neutral.systemImage)
        let notEnrolled = SecurityCheckPresentation(TestData.evaluatedCheck(.mdmEnrollment(enrolled: false, viaDEP: false)), now: now)
        #expect(notEnrolled.statusText == "In Ordnung" && notEnrolled.tone == .positive)
    }

    @Test func unknownShowsErrorAndLastKnownState() {
        var check = SecurityCheck.failed(.gatekeeper, detail: "spctl lieferte nach 15 s kein Ergebnis")
        check.lastKnownState = .good
        let row = SecurityCheckPresentation(check, now: now)
        #expect(row.statusText == "Nicht prüfbar" && row.tone == .neutral && row.systemImage == "questionmark.circle.fill")
        #expect(row.summary == "Konnte nicht geprüft werden: spctl lieferte nach 15 s kein Ergebnis")
        #expect(row.details == ["Zuletzt bekannt: in Ordnung"])
        #expect(row.offers.isEmpty)
    }

    @Test func unknownPendingUpdatesStillOfferTheSearch() {
        let row = SecurityCheckPresentation(.failed(.pendingUpdates, detail: "Plist nicht lesbar"), now: now)
        #expect(row.offers == [.action(.checkForUpdates, title: "Jetzt suchen")])
    }

    @Test func unknownWithCarriedFactsStillShowsTheError() {
        let check = SecurityCheck(kind: .mdmEnrollment, state: .unknown, facts: .mdmEnrollment(enrolled: true, viaDEP: false),
                                  detail: "profiles fehlgeschlagen", lastKnownState: .good)
        let row = SecurityCheckPresentation(check, now: now)
        #expect(row.statusText == "Nicht prüfbar" && row.tone == .neutral)
        #expect(row.summary == "Konnte nicht geprüft werden: profiles fehlgeschlagen")
    }

    @Test func overviewCountsHintsAndPicksWorstState() {
        let overview = SecurityOverview.make(checks: [
            TestData.evaluatedCheck(TestData.firewallOn),
            TestData.evaluatedCheck(TestData.stealthOff),
            TestData.evaluatedCheck(.gatekeeper(enabled: false)),
            .failed(.sip, detail: "x"),
        ], now: now)
        #expect(overview.hintCount == 2 && overview.criticalCount == 1)
        #expect(overview.worstState == .critical && overview.tileTone == .critical)
        #expect(overview.tileCaption == "Mindestens eine Prüfung kritisch")
        #expect(overview.menuBarStatusLine == "Sicherheit: Gatekeeper kritisch")
    }

    @Test func overviewWithWarningsOnly() {
        let overview = SecurityOverview.make(checks: [TestData.evaluatedCheck(TestData.stealthOff)], now: now)
        #expect(overview.hintCount == 1 && overview.tileTone == .warning)
        #expect(overview.tileCaption == "Hinweise zu Schutzfunktionen")
        #expect(overview.menuBarStatusLine == nil)
    }

    @Test func overviewWithoutHints() {
        let overview = SecurityOverview.make(checks: [TestData.evaluatedCheck(TestData.firewallOn)], now: now)
        #expect(overview.hintCount == 0 && overview.tileTone == .positive)
        #expect(overview.tileCaption == "Alles in Ordnung")
        #expect(overview.menuBarStatusLine == nil)
    }

    /// Vor dem ersten v2-Scan gibt es keine Prüfungen: Die Kachel darf weder „in Ordnung“ sagen noch grün sein.
    @Test func overviewWithoutChecksIsNotYetChecked() {
        let overview = SecurityOverview.make(checks: [], now: now)
        #expect(overview.worstState == nil && overview.tileTone == nil && overview.hintCount == 0)
        #expect(overview.tileCaption == "Noch nicht geprüft")
        #expect(overview.menuBarStatusLine == nil)
    }

    @Test func unknownIsGreyInTheTile() {
        let overview = SecurityOverview.make(checks: [TestData.evaluatedCheck(TestData.firewallOn), .failed(.sip, detail: "x")], now: now)
        #expect(overview.worstState == .unknown && overview.tileTone == .neutral && overview.hintCount == 0)
        #expect(overview.tileCaption == "Nicht alle Prüfungen möglich")
    }

    @Test func overviewOrdersChecksForDisplay() {
        let overview = SecurityOverview.make(checks: [
            TestData.evaluatedCheck(.gatekeeper(enabled: true)), TestData.evaluatedCheck(.fileVault(.on)),
        ], now: now)
        #expect(overview.checks.map(\.kind) == [.fileVault, .gatekeeper])
    }

    @Test func severalCriticalChecksAreCountedInThePopover() {
        let overview = SecurityOverview.make(checks: [
            TestData.evaluatedCheck(TestData.firewallOff), TestData.evaluatedCheck(.gatekeeper(enabled: false)),
        ], now: now)
        #expect(overview.menuBarStatusLine == "Sicherheit: 2 Prüfungen kritisch")
    }

    @Test func presentationSnapshotCarriesTheOverview() {
        var snapshot = TestData.snapshot(at: now - 60)
        snapshot.securityChecks = [TestData.evaluatedCheck(TestData.stealthOff)]
        let presentation = PresentationSnapshot.make(snapshot: snapshot, findings: [], events: [], recentAdditions: [], now: now)
        #expect(presentation.security == SecurityOverview.make(checks: snapshot.securityChecks, now: now))
        #expect(PresentationSnapshot.make(snapshot: TestData.snapshot(), findings: [], events: [], recentAdditions: [], now: now)
            .security.checks.isEmpty)
    }

    @Test(arguments: [
        (HelperState?.some(.ready), String?.none),
        (.some(.outdated(installed: 1, expected: 2)), "Der Helper ist veraltet. Bitte in den Einstellungen „Neu installieren“ wählen, um Schutzfunktionen einzuschalten."),
        (.some(.notInstalled), "Zum Einschalten von Schutzfunktionen wird der Helper benötigt (Einstellungen)."),
        (.some(.requiresAdministrator), "Schutzfunktionen können nicht eingeschaltet werden – Helper: Administratorrechte erforderlich."),
        (.some(.missingFromBundle), "Schutzfunktionen können nicht eingeschaltet werden – Helper: Fehlt im App-Bundle."),
        (.none, String?.none),
    ])
    func helperNote(state: HelperState?, expected: String?) {
        #expect(SecurityOverview.helperNote(for: state) == expected)
        #expect(SecurityOverview.canRunHelperActions(state) == (state == .ready))
    }

    @Test func checkForUpdatesStaysAvailableWithoutHelper() {
        #expect(SecurityOverview.isAvailable(.checkForUpdates, helperState: .outdated(installed: 1, expected: 2)))
        #expect(!SecurityOverview.isAvailable(.enableFirewall, helperState: .outdated(installed: 1, expected: 2)))
        #expect(SecurityOverview.isAvailable(.enableFirewall, helperState: .ready))
    }
}
