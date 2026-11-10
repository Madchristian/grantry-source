import Foundation
import GrantryShared
import Testing
@testable import ManagerKit

/// Panel „Zu diesem Zeitpunkt“ und Tabelle „Befunde“ (TM-12.6): Werte, Verbraucher, laufende Befunde und Änderungen an
/// der Zeitmarke, Sprünge und ihre Hinweise. Feste Uhr, Berliner Zeit, deutsche Texte (#214).
@Suite struct WatchbookMomentPresentationTests {
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
    private static let key = ProcessKey(pid: 4_242, startTime: 1_794_000_000_000_000)
    /// 360 Spalten zu 10 s über die letzte Stunde; Spalte 180 liegt um 12:30:05.
    private static let column = 180
    private static var columnTime: Date { now.addingTimeInterval(-1_795) }

    private func presentation(points: [WatchbookPoint] = Fixtures.points(from: now.addingTimeInterval(-3_590),
                                                                           count: 360),
                              events: [WatchbookEvent] = []) -> WatchbookPresentation {
        var builder = WatchbookSeriesBuilder(range: Self.now.addingTimeInterval(-3_600)..<Self.now, width: 360)
        builder.add(points)
        return WatchbookPresentation(series: builder.build(events: events, problems: []), period: .hour,
                                     isEnabled: true, recordingSince: nil, physicalMemory: Self.memory,
                                     calendar: Self.calendar)
    }

    private func moment(_ presentation: WatchbookPresentation,
                        consumers: WatchbookConsumerState = .loaded(nil),
                        liveness: ProcessLiveness = .absent) -> WatchbookPresentation.Moment? {
        presentation.moment(at: Self.column, consumers: consumers, liveness: { _ in liveness })
    }

    private func event(_ kind: WatchbookEvent.Kind = .finding, type: String = SystemFinding.Kind.systemLoad.rawValue,
                       from start: TimeInterval, to end: TimeInterval?, tone: WatchbookEvent.Tone? = .finding,
                       subject: WatchbookSubject? = nil, process: ProcessKey? = nil,
                       summary: String = "CPU insgesamt länger als 2 min über 80 % ausgelastet.") -> WatchbookEvent {
        WatchbookEvent(kind: kind, type: type, start: Self.now.addingTimeInterval(start),
                       end: end.map { Self.now.addingTimeInterval($0) }, tone: kind == .finding ? tone : nil,
                       subject: subject, process: process, summary: summary)
    }

    private func change(_ source: WatchbookChangeSource, at offset: TimeInterval,
                        summary: String = "App installiert: Xcode 27.1") -> WatchbookEvent {
        event(.change, type: source.rawValue, from: offset, to: offset, summary: summary)
    }

    private func processFinding(liveness: ProcessLiveness) throws -> WatchbookPresentation.Jump {
        let finding = event(type: SystemFinding.Kind.processLoad.rawValue, from: -1_900, to: nil,
                            subject: .program("ffmpeg"), process: Self.key,
                            summary: "ffmpeg belegt mehr als 90 % eines Kerns.")
        let shown = try #require(moment(presentation(events: [finding]), liveness: liveness))
        return try #require(shown.findings.first?.jump)
    }

    // MARK: Tabelle „Befunde“

    @Test func findingRowsNewestFirstWithDurationAndCause() {
        let shown = presentation(events: [
            event(from: -3_000, to: -2_460),
            event(type: SystemFinding.Kind.processLoad.rawValue, from: -1_200, to: nil, subject: .program("ffmpeg"),
                  summary: "ffmpeg belegt mehr als 90 % eines Kerns."),
            event(type: SystemFinding.Kind.thermalState.rawValue, from: -2_000, to: -2_000 + 5_400, tone: .critical,
                  subject: .otherAccounts),
            change(.app, at: -1_000),
        ])
        let rows = shown.findingRows
        #expect(rows.map(\.kind) == ["Prozesslast", "Thermik", "Dauerlast"])
        #expect(rows.map(\.start) == ["Sa 12:40", "Sa 12:26", "Sa 12:10"])
        #expect(rows.map(\.duration) == ["läuft · 20 min", "1 h 30 min", "9 min"])
        #expect(rows.map(\.cause) == ["ffmpeg", "Andere Konten", "–"])
        #expect(rows.map(\.isCritical) == [false, true, false])
        #expect(shown.findingsEmptyText == "Keine Befunde in der letzten Stunde.")
    }

    /// Die Wahl eines Befunds setzt die Zeitmarke auf seinen Beginn – vor dem Zeitraum begonnene auf dessen Anfang.
    @Test func selectingAFindingMarksItsStart() throws {
        let inside = event(from: -1_200, to: nil), before = event(from: -7_200, to: -3_000)
        let shown = presentation(events: [inside, before])
        #expect(shown.markerTime(ofFinding: inside.id) == Self.now.addingTimeInterval(-1_200))
        #expect(shown.markerTime(ofFinding: before.id) == Self.now.addingTimeInterval(-3_600))
        #expect(shown.markerTime(ofFinding: UUID()) == nil)
    }

    // MARK: Panel

    @Test func valuesShowOnlyWhatTheLanesDoNot() throws {
        var point = Fixtures.point(at: Self.columnTime)
        point.values[.memoryPressure] = 1
        point.values[.thermalState] = 2
        point.values[.swapUsed] = 1_073_741_824
        let shown = try #require(moment(presentation(points: [point])))
        #expect(shown.time == "Sa 12:30")
        #expect(shown.values.map(\.title) == ["GPU", "Speicherdruck", "Swap", "Thermik", "Akku", "Leistung"])
        #expect(shown.values.map(\.value) == ["5 %", "erhöht", ProcessCleanupPresentation.memoryText(1_073_741_824),
                                             "ernst", "80 % · Netzteil", "4,50 W"])
    }

    @Test func unmeasuredValuesAreLeftOut() throws {
        var point = Fixtures.point(at: Self.columnTime)
        for metric in [WatchbookMetric.batteryCharge, .externalPower, .power, .gpu] { point.values[metric] = nil }
        let shown = try #require(moment(presentation(points: [point])))
        #expect(shown.values.map(\.title) == ["Speicherdruck", "Swap", "Thermik"])
    }

    @Test func consumersNameSystemProcessesAndOtherAccounts() throws {
        let consumers = WatchbookConsumers(
            time: Self.columnTime,
            cpu: [WatchbookConsumer(subject: .program("Xcode"), value: 0.25),
                  WatchbookConsumer(subject: .systemProcess("WindowServer"), value: 0.03),
                  WatchbookConsumer(subject: .otherAccounts, value: 0.01)],
            memory: [WatchbookConsumer(subject: .program("Xcode"), value: Self.memory / 4)])
        let shown = try #require(moment(presentation(), consumers: .loaded(consumers)))
        #expect(shown.cpuConsumers.map(\.name) == ["Xcode", "WindowServer", "Andere Konten"])
        #expect(shown.cpuConsumers.map(\.badge) == ["", "System", ""])
        #expect(shown.cpuConsumers.map(\.value) == ["25 %", "3 %", "1 %"])
        #expect(shown.cpuConsumers.first?.fraction == 0.25)
        #expect(shown.memoryConsumers.map(\.value) == [ProcessCleanupPresentation.memoryText(8_589_934_592)])
        #expect(shown.memoryConsumers.first?.fraction == 0.25)
        #expect(shown.consumersNote == nil)
    }

    @Test func missingConsumersSayWhy() throws {
        #expect(try #require(moment(presentation(), consumers: .loaded(nil))).consumersNote
            == "Für diesen Zeitpunkt sind keine Verbraucher aufgezeichnet.")
        #expect(try #require(moment(presentation(), consumers: .loading)).consumersNote == "Verbraucher werden gelesen …")
    }

    @Test func runningFindingsAndChangesWithinFiveMinutes() throws {
        let running = event(from: -2_000, to: -1_500)
        let ended = event(from: -3_000, to: -2_500)
        let near = change(.autostart, at: -1_600, summary: "Neuer Autostart-Eintrag: com.example.updater")
        let far = change(.app, at: -1_000)
        let wake = event(.system, type: WatchbookSystemEvent.Kind.wake.rawValue, from: -1_700, to: -1_700,
                         summary: "Aufgewacht: Deckel geöffnet")
        let thermal = event(.system, type: WatchbookSystemEvent.Kind.thermalState.rawValue, from: -1_750, to: -1_750,
                            summary: "Thermik ernst")
        let shown = try #require(moment(presentation(events: [running, ended, near, far, wake, thermal])))
        #expect(shown.findings.map(\.id) == [running.id])
        #expect(shown.findings.first?.title == "Dauerlast")
        #expect(shown.findings.first?.time == "12:26 bis 12:35")
        #expect(shown.changes.map(\.id) == [near.id, wake.id])
        #expect(shown.changes.first?.title == "Neuer Autostart-Eintrag")
        #expect(shown.changes.first?.detail == "com.example.updater")
        #expect(shown.changes.first?.time == "12:33")
        #expect(shown.changes.last?.jump == nil)
    }

    @Test func changesJumpToTheirArea() throws {
        let events = [change(.autostart, at: -1_800), change(.networkService, at: -1_790),
                      change(.extensionRecord, at: -1_780), change(.app, at: -1_770), change(.agent, at: -1_760)]
        let shown = try #require(moment(presentation(events: events)))
        #expect(shown.changes.map(\.jump?.target) == [.autostart, .networkConnections, .extensions,
                                                      .historyEntry(events[3].id), .historyEntry(events[4].id)])
        #expect(shown.changes.map(\.jump?.title) == ["In Autostart zeigen", "In Verbindungen zeigen",
                                                     "In Erweiterungen zeigen", "Im Verlauf zeigen", "Im Verlauf zeigen"])
        #expect(shown.changes.allSatisfy { $0.jump?.note == nil })
    }

    // MARK: Sprung zum Prozess (Abnahme 2)

    @Test func runningProcessWithTheSameStartTimeIsAJumpTarget() throws {
        let jump = try processFinding(liveness: .running(startTime: Self.key.startTime))
        #expect(jump.target == .process(Self.key))
        #expect(jump.title == "In Details zeigen")
        #expect(jump.note == nil)
    }

    @Test func endedProcessShowsANoteInsteadOfAWrongTarget() throws {
        #expect(try processFinding(liveness: .absent).note == "ffmpeg läuft nicht mehr.")
    }

    /// Die PID wurde neu vergeben: ein anderer Prozess, kein Sprung.
    @Test func reusedPIDShowsANoteInsteadOfAWrongTarget() throws {
        #expect(try processFinding(liveness: .running(startTime: Self.key.startTime + 1)).note
            == "ffmpeg läuft nicht mehr.")
    }

    @Test func unknownLivenessShowsANote() throws {
        #expect(try processFinding(liveness: .unknown).note == "Ob ffmpeg noch läuft, lässt sich nicht feststellen.")
    }

    @Test func findingsAboutServicesAndExtensionsJumpToTheirArea() throws {
        let service = event(type: SystemFinding.Kind.exposedService.rawValue, from: -1_900, to: nil)
        let risk = event(type: SystemFinding.Kind.extensionRisk.rawValue, from: -1_850, to: nil)
        let load = event(from: -1_820, to: nil)
        let shown = try #require(moment(presentation(events: [service, risk, load])))
        #expect(shown.findings.map(\.jump?.target) == [.networkConnections, .extensions, nil])
    }

    /// Ohne Aufzeichnung oder außerhalb der Reihe gibt es kein Panel.
    @Test func noMomentOutsideTheSeries() {
        #expect(presentation().moment(at: 360, consumers: .loading, liveness: { _ in .absent }) == nil)
        let off = WatchbookPresentation(series: nil, period: .hour, isEnabled: false, recordingSince: nil,
                                        physicalMemory: Self.memory, calendar: Self.calendar)
        #expect(off.moment(at: 0, consumers: .loading, liveness: { _ in .absent }) == nil)
    }
}
