import Foundation
import Testing
@testable import ManagerKit

/// Lagezeile der Übersicht (LB-3.2, #544; Spec 2026-11-10 § 11.3 b): erste zutreffende Regel – noch nicht geprüft,
/// N Punkte auffällig, unvollständig geprüft, ruhig. Nur aus vorhandenen Daten; dieselben Zahlen wie die Kacheln.
@Suite struct DashboardVerdictTests {
    private let scannedAt = TestData.date

    private var scanText: String { "Scan \(scannedAt.formatted(date: .omitted, time: .shortened))" }

    // MARK: - Vor dem ersten Scan

    @Test func notScannedHasOpenShieldAndNoChips() {
        let idle = DashboardVerdict.notScanned(isScanning: false)
        #expect(idle.title == "Noch nicht geprüft")
        #expect(idle.shield == .open)
        #expect(idle.items.isEmpty)
        #expect(idle.reason == "Ein Scan liest Apps, Berechtigungen, Autostart und Agenten ein.")
        #expect(idle.facts == "kein Scan seit dem Start")
        let scanning = DashboardVerdict.notScanned(isScanning: true)
        #expect(scanning.reason == "Der erste Scan läuft; das Urteil folgt, sobald er fertig ist.")
        #expect(scanning.shield == .open)
    }

    // MARK: - Auffällig

    /// Wie im Entwurf: 1 hoch, 1 mittel, 1 Punkt der Sicherheit, 1 Dienst aus dem Netz – 4 Punkte, Grund der hohe Befund.
    @Test func pointsAddUpTheTileNumbersAndTheMostSevereLeads() {
        let verdict = DashboardVerdict(DashboardVerdict.Facts(
            criticalEntries: 1, reviewEntries: 1, leadingEntry: "Fernhilfe darf andere Apps steuern",
            openSecurityChecks: 1, leadingSecurityCheck: "SIP aus", exposedServices: 1, scannedAt: scannedAt))
        #expect(verdict.title == "4 Punkte auffällig")
        #expect(verdict.shield == .finding)
        #expect(verdict.reason == "Fernhilfe darf andere Apps steuern; dazu ein weiterer auffälliger Eintrag, "
            + "ein offener Punkt der Sicherheit und ein Dienst, der Verbindungen aus dem Netz annimmt.")
        #expect(verdict.items == [item("1 kritisch", .critical), item("2 prüfen", .warning),
                                  item("1 aus dem Netz", .warning)])
        #expect(verdict.facts == "\(scanText) · Abdeckung vollständig")
    }

    @Test func singlePointIsSingular() {
        let verdict = DashboardVerdict(DashboardVerdict.Facts(exposedServices: 1, scannedAt: scannedAt))
        #expect(verdict.title == "1 Punkt auffällig")
        #expect(verdict.reason == "Ein Dienst nimmt Verbindungen aus dem Netz an.")
        #expect(verdict.items == [item("1 aus dem Netz", .warning)])
    }

    /// Eine kritische Prüfung der Sicherheit geht einem mittleren Eintrag vor; ein hoher Eintrag ihr.
    @Test func criticalSecurityCheckLeadsBeforeMediumEntries() {
        let verdict = DashboardVerdict(DashboardVerdict.Facts(
            reviewEntries: 2, leadingEntry: "Beispiel ist nicht signiert", openSecurityChecks: 1,
            criticalSecurityChecks: 1, leadingSecurityCheck: "SIP aus", exposedServices: 2, scannedAt: scannedAt))
        #expect(verdict.title == "5 Punkte auffällig")
        #expect(verdict.reason == "Sicherheit: SIP aus; dazu 2 auffällige Einträge und 2 Dienste, die Verbindungen "
            + "aus dem Netz annehmen.")
        #expect(verdict.items == [item("3 prüfen", .warning), item("2 aus dem Netz", .warning)])
    }

    @Test func mediumEntryLeadsBeforeSecurityWarning() {
        let verdict = DashboardVerdict(DashboardVerdict.Facts(
            reviewEntries: 1, leadingEntry: "Beispiel ist nicht signiert", openSecurityChecks: 2,
            leadingSecurityCheck: "2 Updates offen", scannedAt: scannedAt))
        #expect(verdict.reason == "Beispiel ist nicht signiert; dazu 2 offene Punkte der Sicherheit.")
    }

    /// Höchstens drei Chips in der Reihenfolge kritisch, prüfen, aus dem Netz, neu, unvollständig.
    @Test func atMostThreeChipsInFixedOrder() {
        let verdict = DashboardVerdict(DashboardVerdict.Facts(
            criticalEntries: 1, leadingEntry: "x", exposedServices: 1, newEntries: 3, incompleteAreas: 1,
            missingSources: 2, scannedAt: scannedAt))
        #expect(verdict.items == [item("1 kritisch", .critical), item("1 aus dem Netz", .warning),
                                  item("3 neu seit 7 Tagen", .neutral)])
        #expect(verdict.facts == "\(scanText) · 2 Quellen fehlen")
    }

    // MARK: - Unvollständig und ruhig

    /// Ohne Befund, aber mit Lücken: keine Entwarnung und kein Bernstein – Schildform offen.
    @Test func incompleteWithoutFindingsIsOpenAndNotAmber() {
        let verdict = DashboardVerdict(DashboardVerdict.Facts(incompleteAreas: 2, missingSources: 2,
                                                              scannedAt: scannedAt))
        #expect(verdict.title == "Unvollständig geprüft")
        #expect(verdict.shield == .open)
        #expect(verdict.reason == "Keine Befunde in dem, was gelesen wurde; 2 Bereiche sind nicht vollständig.")
        #expect(verdict.items == [item("2 Bereiche unvollständig", .neutral)])
        #expect(verdict.items.allSatisfy { $0.tone == .neutral })
        let one = DashboardVerdict(DashboardVerdict.Facts(incompleteAreas: 1, missingSources: 1, scannedAt: scannedAt))
        #expect(one.reason == "Keine Befunde in dem, was gelesen wurde; ein Bereich ist nicht vollständig.")
        #expect(one.items == [item("1 Bereich unvollständig", .neutral)])
        #expect(one.facts == "\(scanText) · 1 Quelle fehlt")
    }

    /// Ruhig: neue Einträge nur als ruhiger Chip, nicht als Befund; Hinweise (niedrig) zählen nicht.
    @Test func calmShowsNewEntriesAsQuietChip() {
        let verdict = DashboardVerdict(DashboardVerdict.Facts(newEntries: 3, scannedAt: scannedAt))
        #expect(verdict.title == "Ruhig")
        #expect(verdict.shield == .calm)
        #expect(verdict.reason == "Keine Befunde, nichts aus dem Netz erreichbar, alle Quellen gelesen.")
        #expect(verdict.items == [item("3 neu seit 7 Tagen", .neutral)])
        #expect(DashboardVerdict(DashboardVerdict.Facts(scannedAt: nil)).facts == "Abdeckung vollständig")
    }

    // MARK: - Aus dem Snapshot

    /// Dieselben Zahlen wie die Kacheln: auffällige Einträge, offene Punkte der Sicherheit, erreichbare Dienste.
    @Test func factsComeFromThePresentation() {
        let app = TestData.installedApp("Beispiel", bundleID: "com.example.app")
        var snapshot = TestData.appSnapshot([app], grants: [], items: [])
        snapshot.networkListeners = [TestData.listener()]
        let lead = RiskFinding(rule: .unsignedApp, severity: .high, recordID: app.id, message: "Beispiel ist nicht signiert")
        let presentation = PresentationSnapshot.make(snapshot: snapshot, findings: [lead], events: [],
                                                     recentAdditions: [], now: TestData.date)
        let facts = DashboardVerdict.Facts(presentation, scannedAt: scannedAt)
        #expect(facts.criticalEntries == 1)
        #expect(facts.reviewEntries == 0)
        #expect(facts.leadingEntry == "Beispiel ist nicht signiert")
        #expect(facts.exposedServices == presentation.network.exposedCount)
        #expect(facts.openSecurityChecks == presentation.security.hintCount)
        #expect(facts.incompleteAreas == presentation.coverage.incomplete.count)
        #expect(DashboardVerdict(presentation, scannedAt: scannedAt).shield == .finding)
    }

    private func item(_ text: String, _ tone: PresentationTone) -> SystemVerdict.Item {
        SystemVerdict.Item(text: text, tone: tone)
    }
}
