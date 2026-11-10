import Foundation
import Testing
@testable import ManagerKit

/// Ansicht „Aktivität“ im Lagebild (#366): Kennzahlen, Urteil, Spaltenköpfe und Sortierung.
@Suite struct NetworkActivityOverviewTests {
    private var report: TrafficReport {
        TestData.activityFrame([
            ProcessActivity(key: ProcessKey(pid: 1, startTime: 1), shortName: "firefox",
                            rate: TrafficRate(download: 1000, upload: 100),
                            transferred: ByteTotals(received: 5000, sent: 700),
                            connections: [TestData.connectionActivity(remote: "192.0.2.10", download: 1000, upload: 100),
                                          TestData.connectionActivity(remote: "192.0.2.10", port: 80, isNew: true),
                                          TestData.connectionActivity(remote: "192.0.2.20", isGone: true)],
                            isGone: false),
            ProcessActivity(key: ProcessKey(pid: 2, startTime: 1), shortName: "node",
                            rate: TrafficRate(download: 0, upload: 50), transferred: ByteTotals(received: 10, sent: 20),
                            connections: [TestData.connectionActivity(remote: nil, port: nil, isNew: true)],
                            isGone: false),
            TestData.processActivity(3, "curl", transferred: 300, isGone: true),
        ]).report
    }

    @Test func overviewSumsTheWholeMac() {
        let overview = NetworkActivityOverview(report: report)
        #expect(overview.rate == TrafficRate(download: 1000, upload: 150))
        #expect(overview.transferred == ByteTotals(received: 5310, sent: 720))
        #expect(overview.activePrograms == 2)
        #expect(overview.openConnections == 3)
        #expect(overview.newConnections == 2)
        #expect(overview.remoteHosts == 1)
    }

    @Test func verdictNamesActivePrograms() {
        let verdict = NetworkActivityOverview(report: report).verdict
        #expect(verdict.title == "2 Programme im Netz aktiv")
        #expect(verdict.level == .calm)
        #expect(verdict.items == [SystemVerdict.Item(text: "2 neue Verbindungen", tone: .neutral)])
        #expect(verdict.facts == "3 Verbindungen · 1 Gegenstelle · live über nettop")
    }

    @Test func verdictWhenQuiet() {
        let quiet = NetworkActivityOverview(report: TestData.activityFrame([TestData.processActivity(1)]).report).verdict
        #expect(quiet.title == "Gerade keine Netzwerkaktivität")
        #expect(quiet.items.isEmpty)
        #expect(quiet.facts == "0 Verbindungen · 0 Gegenstellen · live über nettop")

        let single = NetworkActivityOverview(report: TestData.activityFrame([
            TestData.processActivity(1, download: 5, connections: [TestData.connectionActivity(download: 5, isNew: true)]),
        ]).report).verdict
        #expect(single.title == "1 Programm im Netz aktiv")
        #expect(single.items == [SystemVerdict.Item(text: "1 neue Verbindung", tone: .neutral)])
    }

    @Test func columnSummaryAddsTopLevelRowsAndFindsPeaks() {
        var filter = NetworkActivityFilter()
        filter.onlyActive = false
        let rows = NetworkActivityPresenter.rows(frame: TestData.activityFrame(report.processes), hostNames: [:],
                                                 filter: filter, query: "",
                                                 sortOrder: NetworkActivityPresenter.defaultSortOrder)
        let summary = NetworkActivityColumnSummary(rows: rows)
        #expect(summary.rate == TrafficRate(download: 1000, upload: 150))
        #expect(summary.bytes == 6030)
        #expect(summary.connections == rows.map(\.connectionCount).reduce(0, +))
        #expect(summary.peak == TrafficRate(download: 1000, upload: 100))
        #expect(summary.heat(500, of: \.download) == 0.5)
        #expect(NetworkActivityColumnSummary(rows: []).heat(0, of: \.upload) == nil)
    }

    @Test func columnsSortAndToggle() {
        #expect(NetworkActivityColumn(sortedBy: NetworkActivityPresenter.defaultSortOrder) == nil)

        let byName = NetworkActivityColumn.sortOrder(selecting: .name, current: NetworkActivityPresenter.defaultSortOrder)
        #expect(NetworkActivityColumn(sortedBy: byName) == .name)
        #expect(byName.first?.order == .forward)
        let reversed = NetworkActivityColumn.sortOrder(selecting: .name, current: byName)
        #expect(reversed.first?.order == .reverse)

        let byDownload = NetworkActivityColumn.sortOrder(selecting: .download, current: byName)
        #expect(NetworkActivityColumn(sortedBy: byDownload) == .download)
        #expect(byDownload.first?.order == .reverse)

        let frame = TestData.activityFrame([TestData.processActivity(1, "b", download: 1),
                                            TestData.processActivity(2, "a", download: 9)])
        let sorted = NetworkActivityPresenter.rows(frame: frame, hostNames: [:], filter: NetworkActivityFilter(),
                                                   query: "", sortOrder: byName)
        #expect(sorted.map(\.title) == ["a", "b"])
        #expect(NetworkActivityPresenter.rows(frame: frame, hostNames: [:], filter: NetworkActivityFilter(), query: "",
                                              sortOrder: reversed).map(\.title) == ["b", "a"])
    }
}
