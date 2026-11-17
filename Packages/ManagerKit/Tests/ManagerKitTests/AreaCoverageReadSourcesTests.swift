import Foundation
import Testing
@testable import ManagerKit

/// Anteil gelesener Quellen je Inventarbereich (#613) – Grundlage der Abdeckungs-Spur über den Listen. Rein aus den
/// vorhandenen Quellzuständen abgeleitet; ein unvollständig gelesener Bereich erscheint nie als vollständig.
@Suite struct AreaCoverageReadSourcesTests {
    private static let calendar = TestData.utcCalendar
    private static let now = TestData.date
    private static let yesterday = TestData.date - TestData.day

    private static func coverage(_ area: InventoryArea, _ snapshot: Snapshot,
                                 activeSources: Set<SourceID>? = nil) -> AreaCoverage {
        AreaCoverage(area: area, snapshot: snapshot, activeSources: activeSources)
    }

    private static func spurDetail(_ coverage: AreaCoverage) -> String {
        coverage.spurDetail(now: now, calendar: calendar)
    }

    // MARK: - Vollständig

    @Test func fullyReadAreaFillsTheSpur() {
        var snapshot = TestData.snapshot()
        snapshot.lastDeliveryBySource = [.launchd: Self.now, .btm: Self.now]
        let coverage = Self.coverage(.autostart, snapshot)

        #expect(coverage.readSources == AreaCoverage.SourceReading(expected: 2, complete: 2, partial: 0))
        #expect(coverage.readSources.fraction == 1)
        #expect(coverage.spurTitle == "Abdeckung vollständig")
        #expect(Self.spurDetail(coverage) == "alle 2 Quellen gelesen · Geprüft heute, 14:13")
    }

    @Test func singleSourceAreaNamesTheSourceInTheSingular() {
        let coverage = Self.coverage(.agents, TestData.snapshot(baseline: [.agents]))
        #expect(coverage.readSources.fraction == 1)
        #expect(coverage.readSources.text == "Quelle gelesen")
    }

    // MARK: - Teilweise

    /// Eine ausgefallene von zwei Quellen: halbe Spur, Text nennt beide Zahlen.
    @Test func failedSourceCountsAsUnread() {
        var snapshot = TestData.snapshot(errors: [SourceError(source: .btm, message: "Helper nicht erreichbar")])
        snapshot.lastDeliveryBySource = [.launchd: Self.now, .btm: Self.yesterday]
        let coverage = Self.coverage(.autostart, snapshot)

        #expect(coverage.state == .lastKnown)
        #expect(coverage.readSources == AreaCoverage.SourceReading(expected: 2, complete: 1, partial: 0))
        #expect(coverage.readSources.fraction == 0.5)
        #expect(coverage.spurTitle == "Abdeckung unvollständig")
        #expect(Self.spurDetail(coverage) == "1 von 2 Quellen gelesen · Stand von gestern, 14:13")
    }

    /// Eingeschränkt gelesene Quelle zählt zur Hälfte: Die Spur ist weder voll noch leer.
    @Test func limitedSourceCountsAsPartlyRead() {
        var snapshot = TestData.snapshot(baseline: [.agents])
        snapshot.sourceLimitations = [SourceLimitation(source: .agents, message: "Netzlaufwerk nicht gelesen")]
        let coverage = Self.coverage(.agents, snapshot)

        #expect(coverage.state == .partial)
        #expect(coverage.readSources == AreaCoverage.SourceReading(expected: 1, complete: 0, partial: 1))
        #expect(coverage.readSources.fraction == 0.5)
        #expect(coverage.readSources.text == "Quelle teilweise gelesen")
    }

    @Test func partlyReadSourceIsNamedNextToTheFullyReadOnes() {
        var snapshot = TestData.snapshot()
        snapshot.sourceLimitations = [SourceLimitation(source: .launchd, message: "Plist nicht auswertbar")]
        let coverage = Self.coverage(.autostart, snapshot)

        #expect(coverage.readSources.fraction == 0.75)
        #expect(coverage.readSources.text == "1 von 2 Quellen gelesen, 1 teilweise")
    }

    /// Nur Zwischenmessungen und fortgeschriebene Einträge sind keine vollständige Lesung.
    @Test func interimOnlyAndOutdatedRecordsCountAsPartlyRead() {
        var outdated = TestData.item(source: .btm)
        outdated.lastVerifiedAt = Self.yesterday
        var snapshot = TestData.snapshot(items: [outdated], baseline: [.btm])
        snapshot.lastInterimDeliveryBySource = [.launchd: Self.now]
        snapshot.baselineSources = [.launchd, .btm]
        let coverage = Self.coverage(.autostart, snapshot)

        #expect(coverage.state == .partial)
        #expect(coverage.readSources == AreaCoverage.SourceReading(expected: 2, complete: 0, partial: 2))
        #expect(coverage.readSources.fraction == 0.5)
    }

    /// Fortgeschriebene Einträge einer nicht erwarteten Quelle: Der Bereich ist unvollständig, also auch die Spur.
    @Test func unattributableOutdatedRecordsNeverShowAFullSpur() {
        var outdated = TestData.item(source: .btm)
        outdated.lastVerifiedAt = Self.yesterday
        let coverage = Self.coverage(.autostart, TestData.snapshot(items: [outdated]), activeSources: [.launchd])

        #expect(!coverage.isComplete)
        #expect(coverage.readSources.fraction.map { $0 < 1 } == true)
        #expect(coverage.readSources.text == "Quelle teilweise gelesen")
    }

    // MARK: - Nichts gelesen

    @Test func unreadAreaShowsAnEmptySpur() {
        let coverage = Self.coverage(.permissions, TestData.snapshot(baseline: []), activeSources: [.tccSystem])

        #expect(coverage.state == .unread)
        #expect(coverage.readSources == AreaCoverage.SourceReading(expected: 1, complete: 0, partial: 0))
        #expect(coverage.readSources.fraction == 0)
        #expect(coverage.spurTitle == "Abdeckung unbekannt")
        #expect(Self.spurDetail(coverage) == "Quelle nicht gelesen · kein bekannter Stand")
    }

    @Test func noSourceOfSeveralReadNamesBoth() {
        let coverage = Self.coverage(.autostart, TestData.snapshot(baseline: []))
        #expect(coverage.readSources.fraction == 0)
        #expect(coverage.readSources.text == "0 von 2 Quellen gelesen")
    }

    /// Vor dem ersten Scan gibt es keine Abdeckung: leere Spur im Entwurfstext.
    @Test func beforeTheFirstScanTheSpurSaysNothingWasRead() {
        #expect(AreaCoverage.spurTitleBeforeScan == "Abdeckung unbekannt")
        #expect(AreaCoverage.spurDetailBeforeScan == "noch nichts gelesen")
    }

    // MARK: - Ohne Quellen

    /// Ohne erwartete Quelle gibt es keinen Anteil: leere Bahn ohne Wert, nie „vollständig“.
    @Test func areaWithoutSourcesHasNoShare() {
        let coverage = Self.coverage(.network, TestData.snapshot(), activeSources: [.launchd])

        #expect(coverage.readSources == AreaCoverage.SourceReading(expected: 0, complete: 0, partial: 0))
        #expect(coverage.readSources.fraction == nil)
        #expect(coverage.readSources.text == "keine Quelle vorgesehen")
        #expect(!coverage.isComplete)
    }

    // MARK: - Keine falsche Entwarnung

    /// Die Spur ist genau dann voll, wenn der Bereich vollständig gelesen ist – über alle Zustände der Tests oben.
    @Test(arguments: [InventoryArea.autostart, .permissions, .agents, .apps])
    func fullSpurIffComplete(_ area: InventoryArea) {
        var limited = TestData.snapshot(baseline: Set(area.sources))
        limited.sourceLimitations = [SourceLimitation(source: area.sources[0], message: "x")]
        let failed = TestData.snapshot(errors: [SourceError(source: area.sources[0], message: "x")],
                                       baseline: Set(area.sources))
        let snapshots = [TestData.snapshot(baseline: Set(area.sources)), limited, failed, TestData.snapshot(baseline: [])]
        for snapshot in snapshots {
            let coverage = Self.coverage(area, snapshot)
            #expect((coverage.readSources.fraction == 1) == coverage.isComplete, "\(coverage.state)")
        }
    }
}
