import Foundation
import GrantryShared
import Testing
@testable import ManagerKit

/// Leistungsaufnahme im Wachbuch (TM-14.5, #398): aus den Helper-Sensoren, je 10-s-Abschnitt gemittelt, im Dateiformat
/// und in der Verdichtung auf Minuten und Spalten. Nicht Gemessenes bleibt leer, nie 0.
@Suite struct WatchbookPowerTests {
    private typealias Fixtures = WatchbookFixtures
    private let start = WatchbookFixtures.dayStart
    private let day = WatchbookFixtures.day

    private func power(_ total: Double?, cpu: Double? = nil, gpu: Double? = nil,
                       neuralEngine: Double? = nil) -> WatchbookPower {
        WatchbookPower(total: total, cpu: cpu, gpu: gpu, neuralEngine: neuralEngine)
    }

    private func point(at seconds: TimeInterval, _ power: WatchbookPower?) -> WatchbookPoint {
        var point = Fixtures.point(at: start.addingTimeInterval(seconds), consumers: false)
        for metric in WatchbookPower.metrics { point.values[metric] = nil }
        power?.write(into: &point.values)
        return point
    }

    // MARK: Aus den Sensoren

    /// Milliwatt des Helpers werden zu Watt; was `powermetrics` nicht liefert, bleibt leer.
    @Test func readingBecomesWatts() throws {
        let reading = SensorReading(cpuMilliwatts: 4_100, gpuMilliwatts: 1_200, aneMilliwatts: nil,
                                    combinedMilliwatts: 5_300)
        let power = try #require(WatchbookPower(reading))
        #expect(power == self.power(5.3, cpu: 4.1, gpu: 1.2))
    }

    /// Ohne jeden Leistungswert (nur Takt oder thermischer Druck) entsteht keine Leistung.
    @Test func readingWithoutPowerIsNoPower() {
        #expect(WatchbookPower(SensorReading(gpuFrequencyMHz: 1_200, thermalPressure: .nominal)) == nil)
    }

    @Test func pointCarriesPowerOnlyWhenGiven() {
        let measured = WatchbookPoint(time: start, snapshot: TaskManagerSnapshot(), currentUID: 501, thermalState: nil,
                                      power: power(6.5, cpu: 4, gpu: 2, neuralEngine: 0.05))
        #expect(measured.values[.power] == 6.5)
        #expect(measured.values[.cpuPower] == 4)
        #expect(measured.values[.gpuPower] == 2)
        #expect(measured.values[.neuralEnginePower] == 0.05)
        let unmeasured = WatchbookPoint(time: start, snapshot: TaskManagerSnapshot(), currentUID: 501,
                                        thermalState: nil, power: nil)
        #expect(WatchbookPower.metrics.allSatisfy { unmeasured.values[$0] == nil })
    }

    // MARK: Je Abschnitt

    /// Der Punkt erhält das Mittel aller Messungen seit dem vorigen Punkt; je Teil nur über die Messungen, die ihn
    /// enthalten.
    @Test func sectionAveragesTheReadingsSinceTheLastPoint() {
        var log = WatchbookPowerLog()
        log.record(power(4, cpu: 3), at: start.addingTimeInterval(2))
        log.record(power(8, cpu: nil), at: start.addingTimeInterval(4))
        log.record(power(6, cpu: 5), at: start.addingTimeInterval(6))
        #expect(log.section(endingAt: start.addingTimeInterval(10)) == power(6, cpu: 4))
        // Danach beginnt der nächste Abschnitt leer.
        #expect(log.section(endingAt: start.addingTimeInterval(20)) == nil)
    }

    /// Messungen aus der Zeit vor dem Abschnitt (Sensoren lange aus, Ruhezustand) zählen nicht.
    @Test func staleReadingsDoNotReachTheNextPoint() {
        var log = WatchbookPowerLog()
        log.record(power(9), at: start)
        #expect(log.section(endingAt: start.addingTimeInterval(60)) == nil)
    }

    /// Für die volle Auflösung um Befunde zählt die jüngste Messung, solange sie frisch ist.
    @Test func latestReadingServesFramesWhileFresh() {
        var log = WatchbookPowerLog()
        log.record(power(5), at: start)
        log.record(power(7), at: start.addingTimeInterval(2))
        #expect(log.latest(at: start.addingTimeInterval(3)) == power(7))
        #expect(log.latest(at: start.addingTimeInterval(30)) == nil)
    }

    /// Die Sensoren messen alle 2 s; mehr als ein Abschnitt an Messungen wird nie gehalten.
    @Test func logStaysBounded() {
        var log = WatchbookPowerLog()
        for second in 0..<1_000 { log.record(power(Double(second % 10)), at: start.addingTimeInterval(Double(second))) }
        #expect(log.count <= WatchbookPowerLog.capacity)
    }

    // MARK: Datei

    /// Teile auf 0,01 W genau, gesamt wie bisher auf 0,1 W.
    @Test func powerRoundTripsAtFileResolution() {
        let written = point(at: 100, power(6.54, cpu: 4.123, gpu: 1.2, neuralEngine: 0.034))
        let read = WatchbookFileFormat.decode(
            WatchbookFileFormat.encode(points: [written], minutes: [], events: [], of: day), of: day).points[0].values
        #expect(read[.power] == 6.5)
        #expect(read[.cpuPower] == 4.12)
        #expect(read[.gpuPower] == 1.2)
        #expect(read[.neuralEnginePower] == 0.03)
    }

    /// Zeilen ohne die neuen Spalten (vor TM-14.5 geschrieben) bleiben lesbar; die Teile sind dort nicht gemessen.
    @Test func rowsWithoutPowerPartsStayReadable() throws {
        let older = WatchbookMetric.allCases.filter { $0.rawValue <= WatchbookMetric.power.rawValue }
        let values = older.map { $0 == .power ? "45" : "" }.joined(separator: ",")
        let text = "W\t1\nP\t100\t\(values)\t\t\nM\t60\t6\t\(values)\t\(values)\t\t\n"
        let contents = WatchbookFileFormat.decode(Array(text.utf8), of: day)
        #expect(contents.brokenLineCount == 0)
        let point = try #require(contents.points.first)
        #expect(point.values[.power] == 4.5)
        #expect(point.values[.cpuPower] == nil)
        #expect(contents.minutes.first?.maximum[.power] == 4.5)
    }

    // MARK: Verdichtung

    /// Minuten halten Mittel und Spitze je Teil über die Punkte, in denen er gemessen wurde.
    @Test func minutesKeepMeanAndPeakOfPower() throws {
        let points = [point(at: 10, power(4, cpu: 3, gpu: 1)), point(at: 20, power(10, cpu: 9, gpu: nil)),
                      point(at: 30, nil)]
        let minute = try #require(WatchbookCompaction.minutes(from: points).first)
        #expect(minute.mean[.power] == 7 && minute.maximum[.power] == 10)
        #expect(minute.mean[.cpuPower] == 6 && minute.maximum[.cpuPower] == 9)
        #expect(minute.mean[.gpuPower] == 1)
        #expect(minute.mean[.neuralEnginePower] == nil)
    }

    /// Spalten über Punkte und Minuten: Minimum, Maximum, Mittel je Teil; ohne Sensoren bleiben Spalten leer, auch wo
    /// andere Werte gemessen sind.
    @Test func columnsSummarizePowerAndKeepGaps() throws {
        let minute = WatchbookCompaction.minutes(from: [point(at: 10, power(2, cpu: 1)), point(at: 20, power(6, cpu: 5))])
        var builder = WatchbookSeriesBuilder(range: start..<start.addingTimeInterval(180), width: 3)
        builder.add(minute)
        builder.add([point(at: 130, nil), point(at: 140, nil)])
        let series = builder.build(events: [], problems: [])
        let first = try #require(series.statistics(of: .power)[0])
        #expect(first.mean == 4 && first.maximum == 6)
        #expect(series.statistics(of: .cpuPower)[0]?.mean == 3)
        #expect(series.statistics(of: .power)[1] == nil)
        #expect(series.statistics(of: .power)[2] == nil)
        #expect(series.statistics(of: .cpuTotal)[2] != nil)
    }
}
