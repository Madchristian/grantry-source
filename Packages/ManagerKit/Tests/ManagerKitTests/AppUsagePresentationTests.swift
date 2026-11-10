import Foundation
import Testing
@testable import ManagerKit

@Suite struct AppUsagePresentationTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// 2026-11-06 15:30 Berlin (14:30 UTC).
    private static let now = Date(timeIntervalSince1970: 1_793_975_400)
    private static let safari = AppUsageHistoryTests.safari
    private static let claude = AppUsageHistoryTests.claude

    private static var history: AppUsageHistory {
        var history = AppUsageHistory()
        // Heute 10:15 Berlin, eine volle Stunde gemessen.
        history.add(AppUsageHistoryTests.sample(at: Date(timeIntervalSince1970: 1_793_956_500), seconds: 3_600, [
            (safari, AppUsageHistoryTests.totals(cpu: 600, network: 2_000_000)),
            (claude, AppUsageHistoryTests.totals(cpu: 1_200)),
        ]))
        // Gestern 20:00 Berlin.
        history.add(AppUsageHistoryTests.sample(at: Date(timeIntervalSince1970: 1_793_905_200), seconds: 600, [
            (claude, AppUsageHistoryTests.totals(cpu: 60, energy: 3_600)),
        ]))
        // Vor zehn Tagen.
        history.add(AppUsageHistoryTests.sample(at: Date(timeIntervalSince1970: 1_793_059_200), seconds: 60, [
            (safari, AppUsageHistoryTests.totals(cpu: 50)),
        ]))
        return history
    }

    private func summary(_ range: AppUsageRange, _ metric: AppUsageMetric = .cpu,
                         _ history: AppUsageHistory = history) -> AppUsageSummary {
        AppUsagePresentation.summary(of: history, range: range, metric: metric, now: Self.now, calendar: Self.calendar)
    }

    @Test func todayHasHourlyBarsAndRowsByMetric() {
        let today = summary(.today)
        #expect(today.rows.map(\.subject.name) == ["claude", "Safari"])
        #expect(today.totals.cpuSeconds == 1_800)
        #expect(today.bars.count == 24)
        #expect(today.bars[10].value == 1_800)
        #expect(today.bars[10].measuredSeconds == 3_600)
        #expect(today.bars[9].measuredSeconds == 0)
        #expect(today.bars.map(\.label).filter { !$0.isEmpty } == ["0", "6", "12", "18"])
        #expect(today.bars[10].detail == "10 Uhr: 30 min")
        #expect(today.bars[9].detail == "9 Uhr: nicht gemessen")
        #expect(today.measuredSeconds == 3_600)
    }

    @Test func rowsFollowTheChosenMetric() {
        #expect(summary(.today, .network).rows.map(\.subject.name) == ["Safari", "claude"])
    }

    @Test func sevenDaysHasDailyBarsWithWeekdays() {
        let week = summary(.sevenDays, .energy)
        #expect(week.bars.count == 7)
        #expect(week.bars.map(\.label) == ["Sa", "So", "Mo", "Di", "Mi", "Do", "Fr"])
        #expect(week.bars[5].value == 3_600)
        #expect(week.bars[5].detail == "Do, 5.11.: 1,0 Wh")
        #expect(week.rows.first?.subject == Self.claude)
        #expect(week.measuredSeconds == 4_200)
    }

    @Test func thirtyDaysLabelsEveryFifthDayFromToday() {
        let month = summary(.thirtyDays)
        #expect(month.bars.count == 30)
        #expect(month.bars.last?.label == "6.11.")
        #expect(month.bars[24].label == "1.11.")
        #expect(month.bars[23].label == "")
        #expect(month.rows.first { $0.subject == Self.safari }?.totals.cpuSeconds == 650)
    }

    /// Gemessen hat nur der Task-Manager ohne nettop und ohne Energiequelle: Netz und Energie sind „nicht
    /// gemessen“, keine gemessene 0 – in Säule, Tooltip, Zeile und Summe.
    @Test(arguments: [AppUsageMetric.network, .energy])
    func unmeasuredMetricIsNotAZero(metric: AppUsageMetric) throws {
        var history = AppUsageHistory()
        history.add(AppUsageHistoryTests.sample(at: Date(timeIntervalSince1970: 1_793_959_260), seconds: 60,
                                                network: false, [(Self.claude, AppUsageHistoryTests.totals(cpu: 30))]))
        let today = summary(.today, metric, history)
        let bar = today.bars[11]
        #expect(bar.value == nil)
        #expect(!bar.isMeasured)
        #expect(bar.detail == "11 Uhr: nicht gemessen")
        #expect(today.rows.first?.totals[metric] == nil)
        #expect(today.totals[metric] == nil)
        #expect(summary(.today, .cpu, history).bars[11].value == 30)
    }

    /// Eine Stunde, in der nettop nur zeitweise lief: gemessen ist, was in dieser Zeit floss.
    @Test func partlyMeasuredNetworkCountsTheMeasuredPart() {
        var history = AppUsageHistory()
        let end = Date(timeIntervalSince1970: 1_793_959_260)
        history.add(AppUsageHistoryTests.sample(at: end, seconds: 60, network: false,
                                                [(Self.claude, AppUsageHistoryTests.totals(cpu: 30))]))
        history.add(AppUsageHistoryTests.sample(at: end.addingTimeInterval(60), seconds: 60,
                                                [(Self.claude, AppUsageHistoryTests.totals(cpu: 30, network: 1_000))]))
        let today = summary(.today, .network, history)
        #expect(today.bars[11].value == 1_000)
        #expect(today.bars[11].detail == "11 Uhr: 1,0 KB")
        #expect(today.totals.networkBytes == 1_000)
    }

    @Test func unmeasuredValuesReadAsNotMeasured() {
        #expect(AppUsageMetric.network.text(nil) == "nicht gemessen")
        #expect(AppUsageMetric.energy.text(nil) == "nicht gemessen")
    }

    @Test func emptyHistoryShowsNoRowsButAllBars() {
        let empty = summary(.today, .cpu, AppUsageHistory())
        #expect(empty.isEmpty)
        #expect(empty.bars.count == 24)
        #expect(empty.bars.allSatisfy { $0.measuredSeconds == 0 })
        #expect(AppUsagePresentation.coverageText(empty, metric: .cpu) == "Noch nicht gemessen")
    }

    @Test func coverageNamesMeasuredTime() {
        #expect(AppUsagePresentation.coverageText(summary(.today), metric: .cpu) == "Gemessen: 1 h")
        #expect(AppUsagePresentation.coverageText(summary(.sevenDays), metric: .network)
            == "Gemessen: 1 h 10 min · Netz: 1 h 10 min")
    }

    @Test(arguments: [(0.0, "0 s"), (42.4, "42 s"), (60, "1 min"), (3_540, "59 min"), (3_600, "1 h"),
                      (8_040, "2 h 14 min")])
    func durationText(seconds: Double, text: String) {
        #expect(AppUsagePresentation.durationText(seconds) == text)
    }

    @Test func metricTitlesAndTexts() {
        #expect(AppUsageMetric.allCases.map(\.title) == ["CPU-Zeit", "Energie", "Netzwerk", "Datenträger"])
        #expect(AppUsageMetric.cpu.text(8_040) == "2 h 14 min")
        #expect(AppUsageMetric.energy.text(12_240) == "3,4 Wh")
        #expect(AppUsageMetric.network.text(1_500_000) == "1,5 MB")
        #expect(AppUsageRange.allCases.map(\.title) == ["Heute", "7 Tage", "30 Tage"])
        #expect(AppUsagePresentation.chartTitle(metric: .cpu, range: .today) == "CPU-Zeit je Stunde")
        #expect(AppUsagePresentation.chartTitle(metric: .energy, range: .thirtyDays) == "Energie je Tag")
    }

    @Test func heatIsRelativeToColumnMaximum() {
        #expect(AppUsagePresentation.heat(25, maximum: 100) == 0.5)
        #expect(AppUsagePresentation.heat(5, maximum: 0) == nil)
    }

    #if DEBUG
    @Test func previewHistoryCoversWorkdays() {
        let preview = AppUsagePresentation.summary(of: AppUsagePreviewData.history, range: .thirtyDays, metric: .cpu,
                                                   now: AppUsagePreviewData.now, calendar: AppUsagePreviewData.calendar)
        #expect(preview.rows.count == 7)
        #expect(preview.bars.filter { $0.measuredSeconds > 0 }.count >= 20)
        #expect(preview.bars.contains { $0.measuredSeconds == 0 })
    }
    #endif
}
