import Foundation
import Testing
@testable import ManagerKit

/// Abnahmekriterien 2 und 3 von #380: Größe einer vollen Tagesdatei und Lesen samt Verdichten von 7 Tagen. Die Werte
/// stehen in der Testausgabe („Wachbuch: …“); belegt werden sie mit `swift test -c release --filter Watchbook`.
@Suite(.serialized) struct WatchbookPerformanceTests {
    private typealias Fixtures = WatchbookFixtures
    private static let pointsPerDay = 8_640

    /// Lange, wechselnde Namen wie im Alltag – ungünstiger als die kurzen Namen der übrigen Tests.
    private static let names = [
        "Google Chrome Helper (Renderer)", "com.apple.WebKit.WebContent", "kernel_task", "WindowServer", "Xcode",
        "SourceKitService", "mds_stores", "Microsoft Teams Helper (Renderer)", "Spotlight", "node",
    ]

    /// Ein Punkt mit Werten voller Stellenzahl und sechs Verbrauchern (deterministisch je Index).
    static func busyPoint(at time: Date, index: Int) -> WatchbookPoint {
        func wave(_ period: Int) -> Double { Double((index * 7_919) % period) / Double(period) }
        var values = WatchbookValues()
        values[.cpuTotal] = 0.05 + 0.9 * wave(97)
        values[.cpuPerformance] = 0.05 + 0.9 * wave(89)
        values[.cpuEfficiency] = 0.05 + 0.9 * wave(83)
        values[.memoryUsed] = 12e9 + 3e9 * wave(101)
        values[.memoryCompressed] = 2e9 * wave(103)
        values[.swapUsed] = 1.5e9 * wave(107)
        values[.memoryPressure] = Double(index % 3)
        values[.diskRead] = 250e6 * wave(109)
        values[.diskWrite] = 180e6 * wave(113)
        values[.networkReceived] = 95e6 * wave(127)
        values[.networkSent] = 12e6 * wave(131)
        values[.gpu] = wave(137)
        values[.thermalState] = Double(index % 4)
        values[.batteryCharge] = 0.2 + 0.8 * wave(139)
        values[.externalPower] = Double(index % 2)
        values[.power] = 45 * wave(149)
        let consumer = { (offset: Int, value: Double, kind: Int) -> WatchbookConsumer in
            let name = names[(index + offset) % names.count]
            let subject: WatchbookSubject = switch kind {
            case 0: .program(name)
            case 1: .systemProcess(name)
            default: .otherAccounts
            }
            return WatchbookConsumer(subject: subject, value: value)
        }
        return WatchbookPoint(
            time: time, values: values,
            cpuConsumers: [consumer(0, 0.31 * wave(151), 0), consumer(1, 0.12 * wave(157), 1),
                           consumer(2, 0.05 * wave(163), 2)],
            memoryConsumers: [consumer(3, 4.2e9 * wave(167), 0), consumer(4, 2.1e9 * wave(173), 1),
                              consumer(5, 0.9e9 * wave(179), 0)]
        )
    }

    static func busyDay(_ day: WatchbookDay) -> [WatchbookPoint] {
        (0..<pointsPerDay).map { busyPoint(at: day.start.addingTimeInterval(Double($0) * 10 + 5), index: $0) }
    }

    /// Abnahmekriterium 3: 8 640 Punkte, wie der Recorder sie schreibt (je Minute ein Block mit eigener Namenstabelle).
    @Test func dayFileWith8640PointsStaysUnderTwoMegabytes() throws {
        try Fixtures.withStore { store in
            let points = Self.busyDay(Fixtures.day)
            for batch in stride(from: 0, to: points.count, by: 6) {
                try store.append(points: Array(points[batch..<min(batch + 6, points.count)]), events: [])
            }
            let size = try Fixtures.size(of: Fixtures.url(of: Fixtures.day, in: store))
            print("Wachbuch: Tagesdatei mit \(points.count) Punkten: \(size) Byte")
            #expect(size < 2_000_000)
            #expect(store.records(in: Fixtures.day.start..<Fixtures.day.end).points.count == points.count)
        }
    }

    /// Abnahmekriterium 2: 7 Tage lesen und auf 1 000 Spalten verdichten – sechs verdichtete Tage und zwei mit
    /// 10-s-Punkten, wie sie nach einer Woche Aufzeichnung vorliegen.
    @Test func readingAndCompactingSevenDaysIsFast() throws {
        try Fixtures.withStore { store in
            let today = WatchbookDay(index: Fixtures.day.index + 7)
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            for offset in 0...7 {
                let day = WatchbookDay(index: Fixtures.day.index + offset)
                let points = Self.busyDay(day)
                let events = (0..<12).map {
                    Fixtures.event(start: day.start.addingTimeInterval(Double($0) * 7_000), end: nil)
                }
                var bytes: [UInt8] = []
                if offset < 6 {
                    bytes = WatchbookFileFormat.encode(points: [], minutes: WatchbookCompaction.minutes(from: points),
                                                       events: events, of: day)
                } else {
                    for batch in stride(from: 0, to: points.count, by: 6) {
                        bytes += WatchbookFileFormat.encode(points: Array(points[batch..<batch + 6]), minutes: [],
                                                            events: batch == 0 ? events : [], of: day)
                    }
                }
                try Data(bytes).write(to: Fixtures.url(of: day, in: store))
            }
            let now = today.start.addingTimeInterval(86_000)
            var fastest = Duration.seconds(3_600)
            var series: WatchbookSeries?
            for _ in 0..<5 {
                let elapsed = ContinuousClock().measure {
                    series = store.series(.week, endingAt: now, width: 1_000)
                }
                fastest = min(fastest, elapsed)
            }
            let result = try #require(series)
            print("Wachbuch: 7 Tage lesen und auf 1 000 Spalten verdichten: \(fastest)")
            #expect(result.statistics(of: .cpuTotal).compactMap { $0 }.count > 900)
            #expect(result.events.count == 8 * 12)
            #if DEBUG
            #expect(fastest < .seconds(5))
            #else
            #expect(fastest < .milliseconds(150))
            #endif
        }
    }
}
