import Foundation
import Testing
@testable import ManagerKit

/// Darstellung des Tabs „Wachbuch“ (TM-12.5): Urteil über den Zeitraum, Spuren, Marken, Thermikband, Zeitachse und
/// Werte unter der Zeitmarke. Feste Uhr, Berliner Zeit, deutsche Texte (#214).
@Suite struct WatchbookPresentationTests {
    private typealias Fixtures = WatchbookFixtures

    /// Sa, 7. November 2026, 13:00 Berliner Zeit.
    private static let now = Fixtures.dayStart.addingTimeInterval(12 * 3_600)
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return calendar
    }()
    private static let memory = 32.0 * 1_073_741_824

    private func series(_ period: WatchbookPeriod = .hour, width: Int = 360, points: [WatchbookPoint] = [],
                        events: [WatchbookEvent] = [], problems: [WatchbookProblem] = []) -> WatchbookSeries {
        var builder = WatchbookSeriesBuilder(range: Self.now.addingTimeInterval(-period.duration)..<Self.now, width: width)
        builder.add(points)
        return builder.build(events: events, problems: problems)
    }

    private func presentation(_ series: WatchbookSeries?, period: WatchbookPeriod = .hour, isEnabled: Bool = true,
                              since: Date? = nil) -> WatchbookPresentation {
        WatchbookPresentation(series: series, period: period, isEnabled: isEnabled, recordingSince: since,
                              physicalMemory: Self.memory, calendar: Self.calendar)
    }

    /// Ein Punkt alle 10 s über die ganze letzte Stunde.
    private var fullHour: [WatchbookPoint] {
        Fixtures.points(from: Self.now.addingTimeInterval(-3_590), count: 360)
    }

    private func finding(_ type: SystemFinding.Kind = .systemLoad, from start: TimeInterval, to end: TimeInterval?,
                         tone: WatchbookEvent.Tone = .finding,
                         summary: String = "CPU insgesamt länger als 2 min über 80 % ausgelastet.") -> WatchbookEvent {
        WatchbookEvent(kind: .finding, type: type.rawValue, start: Self.now.addingTimeInterval(start),
                       end: end.map { Self.now.addingTimeInterval($0) }, tone: tone, subject: nil, summary: summary)
    }

    private func change(at offset: TimeInterval, source: WatchbookChangeSource = .app) -> WatchbookEvent {
        let time = Self.now.addingTimeInterval(offset)
        return WatchbookEvent(kind: .change, type: source.rawValue, start: time, end: time, tone: nil, subject: nil,
                              summary: "App installiert: Xcode 27.1")
    }

    // MARK: Zustand und Urteil

    @Test func offShowsTheSwitchAndNoData() {
        let shown = presentation(series(points: fullHour), isEnabled: false)
        #expect(shown.state == .off)
        #expect(shown.status.title == "Wachbuch ist aus")
        #expect(!shown.status.hasFinding)
        #expect(shown.status.facts == "Aufzeichnung aus")
        #expect(shown.lanes.isEmpty)
    }

    @Test func beforeTheFirstReadItIsLoading() {
        #expect(presentation(nil).state == .loading)
    }

    @Test func enabledWithoutAnythingRecordedIsEmpty() {
        let shown = presentation(series())
        #expect(shown.state == .empty)
        #expect(shown.status.title == "Noch keine Aufzeichnung")
    }

    @Test func quietOverTheWholePeriod() {
        let shown = presentation(series(points: fullHour))
        #expect(shown.state == .recorded)
        #expect(shown.status.title == "Ruhig seit 1 Stunde")
        #expect(!shown.status.hasFinding)
    }

    @Test func quietSinceTheRecordingStartedWithinThePeriod() {
        let points = Fixtures.points(from: Self.now.addingTimeInterval(-25 * 60 + 10), count: 150)
        #expect(presentation(series(points: points)).status.title == "Ruhig seit 25 Minuten")
        let day = series(.day, width: 480, points: Fixtures.points(from: Self.now.addingTimeInterval(-5 * 3_600),
                                                                   count: 1_800, every: 10))
        #expect(presentation(day, period: .day).status.title == "Ruhig seit 5 Stunden")
    }

    @Test func findingsAreCountedWithTheOngoingOnes() {
        let events = [finding(from: -20 * 3_600, to: -19 * 3_600),
                      finding(.memoryPressure, from: -3_600, to: nil, summary: "macOS meldet erhöhten Speicherdruck.")]
        let shown = presentation(series(.day, width: 480, points: fullHour, events: events), period: .day)
        #expect(shown.status.title == "2 Befunde in den letzten 24 Stunden · 1 läuft")
        #expect(shown.status.hasFinding)
        #expect(shown.status.items.map(\.text) == ["Dauerlast", "Speicherdruck"])
        #expect(shown.status.items.map(\.tone) == [.warning, .warning])
    }

    @Test func criticalFindingsLeadTheChipsAndChangesFillThem() {
        let events = [finding(.thermalState, from: -600, to: -300, tone: .critical,
                              summary: "macOS meldet einen kritischen thermischen Zustand."),
                      finding(from: -1_800, to: -1_500), change(at: -120)]
        let shown = presentation(series(points: fullHour, events: events))
        #expect(shown.status.title == "2 Befunde in der letzten Stunde")
        #expect(shown.status.items.map(\.text) == ["1 kritisch", "Dauerlast", "1 Änderung"])
        #expect(shown.status.items.map(\.tone) == [.critical, .warning, .neutral])
        #expect(shown.eventSummary == "2 Befunde · 1 Änderung")
    }

    @Test func factsNameWhenRecordingStarted() {
        let sameDay = Self.now.addingTimeInterval(-3 * 3_600 - 46 * 60)
        #expect(presentation(series(points: fullHour), since: sameDay).status.facts == "Aufzeichnung an seit 09:14")
        let earlier = Self.now.addingTimeInterval(-5 * 86_400)
        #expect(presentation(series(points: fullHour), since: earlier).status.facts
            == "Aufzeichnung an seit Mo. 2. Nov., 13:00")
        #expect(presentation(series(points: fullHour)).status.facts == "Aufzeichnung an")
    }

    @Test func unreadableFilesAreNamedInTheFacts() {
        let shown = presentation(series(points: fullHour, problems: [.setAside(name: "x.watchbook")]))
        #expect(shown.status.facts == "Aufzeichnung an · 1 Datei nicht lesbar")
    }

    // MARK: Spuren und Werte

    @Test func lanesCarryTheCompactedColumns() {
        let shown = presentation(series(points: fullHour))
        #expect(shown.lanes.map(\.kind) == [.cpu, .memory, .network, .disk])
        #expect(shown.lanes.map(\.title) == ["CPU", "Arbeitsspeicher", "Netz", "Datenträger"])
        #expect(shown.lanes[0].upper.count == 360)
        #expect(shown.lanes[0].upper.last??.mean == 0.25)
        #expect(shown.lanes[0].lower == nil)
        #expect(shown.lanes[0].scale == .fraction)
        #expect(shown.lanes[1].scale == .total(Self.memory))
        #expect(shown.lanes[2].upper.last??.mean == 12_300)
        #expect(shown.lanes[2].lower?.last??.mean == 1_000)
        #expect(shown.lanes[3].scale == .rate)
    }

    @Test func gapsStayEmptyAndShowNoValue() {
        let points = Fixtures.points(from: Self.now.addingTimeInterval(-3_590), count: 120)
            + Fixtures.points(from: Self.now.addingTimeInterval(-1_190), count: 120)
        let shown = presentation(series(points: points))
        #expect(shown.lanes[0].upper[150] == nil)
        #expect(shown.readout(at: 150).laneValues == ["–", "–", "–", "–"])
        #expect(shown.readout(at: 150).thermal == "nicht gemessen")
    }

    @Test func readoutShowsTheValuesUnderTheMarker() {
        let shown = presentation(series(points: fullHour))
        let readout = shown.readout(at: 180)
        #expect(readout.time == "Sa 12:30")
        #expect(readout.laneValues == ["25 %", "8\u{00A0}GB", "↓ 12 KB/s · ↑ 1,0 KB/s", "↓ 100 B/s · ↑ 4,0 KB/s"])
        #expect(readout.thermal == "normal")
    }

    @Test func withoutMarkerTheNewestMeasuredColumnCounts() {
        let points = Fixtures.points(from: Self.now.addingTimeInterval(-3_590), count: 300)
        let readout = presentation(series(points: points)).readout(at: nil)
        #expect(readout.time == "jetzt")
        #expect(readout.laneValues.first == "25 %")
    }

    @Test func thermalBandColoursOnlyWhatStandsOut() {
        let points = (0..<4).map { level -> WatchbookPoint in
            var point = Fixtures.point(at: Self.now.addingTimeInterval(Double(level - 3) * 900 - 5))
            point.values[.thermalState] = Double(level)
            return point
        }
        let shown = presentation(series(width: 4, points: points))
        #expect(shown.thermal == [.neutral, .warning, .warning, .critical])
        #expect((0..<4).map { shown.readout(at: $0).thermal } == ["normal", "mäßig", "ernst", "kritisch"])
        #expect(presentation(series(width: 4, points: [points[0]])).thermal == [.neutral, nil, nil, nil])
    }

    // MARK: Ereignisleiste

    @Test func marksSitAtTheirShareOfThePeriod() {
        let events = [finding(from: -1_800, to: -900), finding(from: -7_200, to: nil), change(at: -360)]
        let marks = presentation(series(points: fullHour, events: events)).marks
        #expect(marks.map(\.style) == [.finding, .finding, .change])
        #expect(marks[0].start == 0 && marks[0].end == 1)
        #expect(marks[1].start == 0.5 && marks[1].end == 0.75)
        #expect(marks[2].start == 0.9 && marks[2].end == 0.9)
        #expect(marks[2].source == .change(.app))
    }

    @Test func markTextsNameKindTimeAndReason() {
        let events = [finding(from: -1_800, to: -900), finding(from: -600, to: nil, tone: .critical), change(at: -360),
                      WatchbookSystemEvent.wake(at: Self.now.addingTimeInterval(-60), reason: "lid")]
        let texts = presentation(series(points: fullHour, events: events)).marks.map(\.text)
        #expect(texts == [
            "Befund Dauerlast, 12:30 bis 12:45: CPU insgesamt länger als 2 min über 80 % ausgelastet.",
            "Befund Dauerlast, kritisch, seit 12:50, läuft: CPU insgesamt länger als 2 min über 80 % ausgelastet.",
            "Änderung um 12:54: App installiert: Xcode 27.1",
            "Systemereignis um 12:59: Aufgewacht, Grund laut macOS: lid.",
        ])
    }

    @Test func sleepIsASpanAndStateChangesStayInBandAndLane() {
        let sleep = WatchbookSystemEvent.sleep(from: Self.now.addingTimeInterval(-2_700),
                                               to: Self.now.addingTimeInterval(-1_800))
        let thermal = WatchbookSystemEvent.event(.thermalState, from: Self.now.addingTimeInterval(-600),
                                                 to: Self.now.addingTimeInterval(-600), summary: "Thermik mäßig.")
        let marks = presentation(series(points: fullHour, events: [sleep, thermal])).marks
        #expect(marks.count == 1)
        #expect(marks[0].style == .system && marks[0].source == .system(.sleep))
        #expect(marks[0].start == 0.25 && marks[0].end == 0.5)
    }

    // MARK: Zeitachse und Zeitmarke

    @Test func hourAxisShowsQuarterHoursAndNow() {
        let axis = presentation(series(points: fullHour)).axis
        #expect(axis.map(\.label) == ["12:15", "12:30", "12:45", "jetzt"])
        #expect(axis.map(\.position) == [0.25, 0.5, 0.75, 1])
    }

    @Test func weekAxisShowsWeekdaysAtMidnight() {
        let week = series(.week, width: 672, points: fullHour)
        let axis = presentation(week, period: .week).axis
        #expect(axis.map(\.label) == ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa", "jetzt"])
        #expect(abs(axis[0].position - 11.0 / 168) < 1e-9)
    }

    @Test func dayAxisNamesTheNewDayAtMidnight() {
        let day = series(.day, width: 480, points: fullHour)
        let axis = presentation(day, period: .day).axis
        #expect(axis.map(\.label) == ["15:00", "18:00", "21:00", "Sa", "03:00", "06:00", "09:00", "jetzt"])
    }

    @Test func arrowKeysStepByAFixedDuration() {
        #expect(presentation(series(points: fullHour)).markerStep == 6)
        #expect(presentation(series(.week, width: 672, points: fullHour), period: .week).markerStep == 4)
        #expect(presentation(series(width: 20, points: fullHour)).markerStep == 1)
    }

    @Test func detailNamesThePeriod() {
        #expect(presentation(series(points: fullHour)).detail
            == "Letzte Stunde · Zeitmarke per Klick, Ziehen oder Pfeiltasten")
        #expect(presentation(series(.week, width: 672), period: .week, isEnabled: false).detail
            == "Letzte 7 Tage · gemeinsame Zeitachse")
    }
}
