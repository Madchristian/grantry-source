import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Längerer Leistungsverlauf im Tab „Leistung“ (TM-14.5, #398): Zeiträume, Kennzahlen aus der Wachbuch-Reihe und das
/// Nachladen nur je neuer Spalte, solange die Ansicht sichtbar ist.
@Suite struct PowerHistoryPresentationTests {
    private let start = WatchbookFixtures.dayStart

    /// Eine Reihe über `period` mit `width` Spalten; `power(column)` liefert gesamt und CPU in Watt oder `nil`.
    private func series(_ period: WatchbookPeriod, width: Int,
                        power: (Int) -> (total: Double, cpu: Double?)?) -> WatchbookSeries {
        let end = start.addingTimeInterval(period.duration)
        var builder = WatchbookSeriesBuilder(range: start..<end, width: width)
        let spacing = period.duration / Double(width)
        let points = (0..<width).compactMap { column -> WatchbookPoint? in
            guard let watts = power(column) else { return nil }
            var point = WatchbookFixtures.point(at: start.addingTimeInterval(Double(column + 1) * spacing),
                                                consumers: false)
            WatchbookPower(total: watts.total, cpu: watts.cpu, gpu: nil, neuralEngine: nil).write(into: &point.values)
            return point
        }
        // Je Spalte ein Minutenwert, damit er die ganze Spalte abdeckt.
        builder.add(points.map { point in
            WatchbookMinute(start: point.time.addingTimeInterval(-spacing), count: 1, mean: point.values,
                            maximum: point.values, cpuConsumers: [], memoryConsumers: [])
        })
        return builder.build(events: [], problems: [])
    }

    @Test func rangesOfferLiveWindowsThenWatchbookPeriods() {
        #expect(PowerRange.allCases == [.live(.oneMinute), .live(.fiveMinutes), .live(.fifteenMinutes),
                                        .watchbook(.hour), .watchbook(.sixHours), .watchbook(.day),
                                        .watchbook(.week)])
        #expect(PowerRange.allCases.map(\.title) == ["60 s", "5 min", "15 min", "1 h", "6 h", "24 h", "7 Tage"])
    }

    /// Mittel über gemessene Spalten, Spitze aus den Maxima, Teile ohne Messung als „–“, Gemessen über die Spalten mit
    /// Wert.
    @Test func statsSummarizeTheMeasuredColumns() {
        let page = PowerHistoryPage(series: series(.day, width: 24) { hour in
            switch hour {
            case 8: (4, 3)
            case 9: (8, 5)
            case 20: (6, nil)
            default: nil
            }
        }, period: .day)
        #expect(page.hasValues)
        #expect(!page.isComplete)
        #expect(page.stats == [
            PerformanceStat("Mittel", "6,00 W"), PerformanceStat("Spitze", "8,00 W"), PerformanceStat("CPU", "4,00 W"),
            PerformanceStat("GPU", "–"), PerformanceStat("Neural Engine", "–"),
            PerformanceStat("Gemessen", "3 h von 24 h"),
        ])
        #expect(page.values(.total).count == 24)
        #expect(page.values(.total)[7] == nil)
        #expect(page.values(.total)[8] == 4)
        #expect(page.window == 86_400)
        #expect(page.spacing == 3_600)
    }

    @Test func fullyMeasuredHourIsComplete() {
        let page = PowerHistoryPage(series: series(.hour, width: 60) { _ in (5, 4) }, period: .hour)
        #expect(page.isComplete)
        #expect(page.stats.last == PerformanceStat("Gemessen", "60 von 60 min"))
    }

    /// Ohne Leistungswerte keine Kennzahlen – nicht gemessen ist nicht 0.
    @Test func withoutPowerEverythingIsMissing() {
        let page = PowerHistoryPage(series: series(.week, width: 7) { _ in nil }, period: .week)
        #expect(!page.hasValues)
        #expect(page.stats.allSatisfy { $0.value == "–" })
    }

    @Test(arguments: [
        (2_580.0, WatchbookPeriod.hour, "43 von 60 min"),
        (7_500.0, .sixHours, "2 h 5 min von 6 h"),
        (24_180.0, .day, "6 h 43 min von 24 h"),
        (40_800.0, .week, "11 h 20 min von 7 Tagen"),
    ])
    func coverageText(seconds: Double, period: WatchbookPeriod, expected: String) {
        #expect(PowerHistoryPage.coverageText(seconds, of: period) == expected)
    }
}

/// Lädt die Wachbuch-Reihe, solange die Ansicht sichtbar ist, und danach nur je neuer Spalte (mindestens 10 s).
@MainActor
@Suite struct PowerHistoryModelTests {
    private final class Source: WatchbookSeriesReading {
        let requests = Mutex<[(WatchbookPeriod, Date, Int)]>([])

        func series(_ period: WatchbookPeriod, endingAt end: Date, width: Int) async -> WatchbookSeries {
            requests.withLock { $0.append((period, end, width)) }
            return WatchbookSeriesBuilder(range: end.addingTimeInterval(-period.duration)..<end, width: width)
                .build(events: [], problems: [])
        }
    }

    @Test func reloadsOncePerColumnUntilCancelled() async {
        let source = Source()
        let sleeps = Mutex<[Duration]>([])
        let model = PowerHistoryModel(source: source, now: { WatchbookFixtures.dayStart }, sleep: { duration in
            let count = sleeps.withLock { $0.append(duration); return $0.count }
            if count == 3 { throw CancellationError() }
        })
        await model.follow(.day, width: 720)
        // 24 h auf 720 Spalten: alle 120 s neu lesen.
        #expect(sleeps.withLock { $0 } == [.seconds(120), .seconds(120), .seconds(120)])
        #expect(source.requests.withLock { $0.map(\.0) } == [.day, .day, .day])
        #expect(source.requests.withLock { $0.map(\.2) } == [720, 720, 720])
        #expect(model.page?.window == 86_400)
    }

    /// Kurze Zeiträume lesen höchstens alle 10 s (Takt der Wachbuch-Punkte).
    @Test func readsAtMostEveryTenSeconds() async {
        let sleeps = Mutex<[Duration]>([])
        let model = PowerHistoryModel(source: Source(), now: { WatchbookFixtures.dayStart }, sleep: { duration in
            sleeps.withLock { $0.append(duration) }
            throw CancellationError()
        })
        await model.follow(.hour, width: 2_000)
        #expect(sleeps.withLock { $0 } == [.seconds(10)])
    }

    /// Ohne Wachbuch (kein Recorder) gibt es nichts zu lesen.
    @Test func withoutSourceThereIsNoPage() async {
        let model = PowerHistoryModel(source: nil, now: { WatchbookFixtures.dayStart }, sleep: { _ in })
        await model.follow(.hour, width: 100)
        #expect(model.page == nil)
    }

    /// Ein neuer Zeitraum ersetzt die Seite des vorigen.
    @Test func switchingPeriodsReplacesThePage() async {
        let model = PowerHistoryModel(source: Source(), now: { WatchbookFixtures.dayStart }, sleep: { _ in
            throw CancellationError()
        })
        await model.follow(.day, width: 100)
        #expect(model.page?.period == .day)
        await model.follow(.hour, width: 100)
        #expect(model.page?.period == .hour)
    }
}
