import Foundation
import Testing
@testable import ManagerKit

/// Befunde des Wachbuchs mit Beginn und Ende (Spec 2026-11-08 §5.1, TM-12.3): Jeder Befund erscheint einmal laufend
/// und einmal mit Ende – mit derselben ID, auch wenn er länger läuft als das Auswertungsfenster.
@Suite struct WatchbookFindingLogTests {
    private typealias Fixtures = FindingFixtures

    /// CPU gesamt je 10-s-Punkt ab 0 s.
    private func record(_ loads: [Double?], in log: inout WatchbookFindingLog,
                        from offset: TimeInterval = 0) -> [WatchbookEvent] {
        let points = Fixtures.points(loads, from: offset) { $0[.cpuTotal] = $1 }
        return points.flatMap { log.record($0, processes: ProcessLoadSample(time: $0.time, processes: [:])) }
    }

    private func load(_ minutes: Double, _ value: Double) -> (Double?, Int) {
        (value, Int(minutes * 6))
    }

    @Test func reportsBeginOnceAndEndWithTheSameID() throws {
        var log = WatchbookFindingLog()
        let events = record(Fixtures.values([load(1, 0.2), load(3, 0.95), load(2, 0.2)]), in: &log)
        try #require(events.count == 2)
        let (begin, end) = (events[0], events[1])
        #expect(begin.id == end.id)
        #expect(begin.kind == .finding)
        #expect(begin.type == SystemFinding.Kind.systemLoad.rawValue)
        #expect(begin.start == Fixtures.time(60))
        #expect(begin.end == nil)
        #expect(end.start == Fixtures.time(60))
        #expect(end.end == Fixtures.time(230))
        #expect(log.findings.map(\.end) == [Fixtures.time(230)])
    }

    @Test func nothingWithoutFinding() {
        var log = WatchbookFindingLog()
        #expect(record(Fixtures.values([load(10, 0.5)]), in: &log).isEmpty)
        #expect(log.findings.isEmpty)
    }

    /// Länger als das Auswertungsfenster (15 min): Beginn und ID bleiben, es entsteht kein zweiter Befund.
    @Test func longFindingKeepsItsStart() throws {
        var log = WatchbookFindingLog()
        let events = record(Fixtures.values([load(40, 0.95), load(2, 0.1)]), in: &log)
        try #require(events.count == 2)
        #expect(Set(events.map(\.id)).count == 1)
        #expect(events.map(\.start) == [Fixtures.time(0), Fixtures.time(0)])
        #expect(events[1].end == Fixtures.time(2_390))
    }

    /// Ein Ruhezustand ist eine Lücke: Er beendet keinen Befund; gilt die Bedingung danach nicht mehr, endet der Befund
    /// mit dem letzten Punkt davor.
    @Test func sleepGapEndsAtTheLastPointBeforeIt() throws {
        var log = WatchbookFindingLog()
        var events = record(Fixtures.values([load(3, 0.95)]), in: &log)
        events += record(Fixtures.values([load(3, 0.1)]), in: &log, from: 8 * 3_600)
        try #require(events.count == 2)
        #expect(events[1].end == Fixtures.time(170))
    }

    /// Wird ein Befund kritisch, ersetzt ein Eintrag mit derselben ID den laufenden.
    @Test func escalationRewritesTheRunningFinding() throws {
        var log = WatchbookFindingLog()
        let points = Fixtures.points(Fixtures.values([(1, 12), (2, 6)])) { $0[.memoryPressure] = $1 }
        let events = points.flatMap { log.record($0, processes: ProcessLoadSample(time: $0.time, processes: [:])) }
        try #require(events.count == 2)
        #expect(events.map(\.tone) == [.finding, .critical])
        #expect(events[0].id == events[1].id)
        #expect(events.allSatisfy { $0.end == nil })
    }

    @Test func processFindingsCarryTheirProgram() throws {
        var log = WatchbookFindingLog()
        let key = ProcessKey(pid: 42, startTime: 7)
        var events: [WatchbookEvent] = []
        for index in 0..<40 {
            let time = Fixtures.time(Double(index) * 10)
            let load = ProcessLoad(coreShare: index < 32 ? 1.0 : 0.1, subject: .program("ffmpeg"))
            events += log.record(WatchbookPoint(time: time, values: WatchbookValues(), cpuConsumers: [],
                                                memoryConsumers: []),
                                 processes: ProcessLoadSample(time: time, processes: [key: load]))
        }
        try #require(events.count == 2)
        #expect(events.allSatisfy { $0.type == SystemFinding.Kind.processLoad.rawValue })
        #expect(events.allSatisfy { $0.subject == .program("ffmpeg") })
        #expect(events[1].end == Fixtures.time(310))
    }

    /// Beim Ausschalten oder Beenden endet ein laufender Befund mit dem letzten Punkt, an dem er noch lief.
    @Test func closeAllEndsRunningFindingsAtTheirLastPoint() throws {
        var log = WatchbookFindingLog()
        let begun = record(Fixtures.values([load(4, 0.95)]), in: &log)
        try #require(begun.count == 1)
        let closed = log.closeAll()
        #expect(closed.map(\.id) == begun.map(\.id))
        #expect(closed.map(\.end) == [Fixtures.time(230)])
        #expect(log.closeAll().isEmpty)
        #expect(record(Fixtures.values([load(1, 0.1)]), in: &log, from: 300).isEmpty)
    }

    /// Ein schon beendeter Befund bleibt eine Zeit lang im Fenster; er wird nicht erneut gemeldet.
    @Test func endedFindingIsReportedOnce() {
        var log = WatchbookFindingLog()
        let events = record(Fixtures.values([load(3, 0.95), load(10, 0.1)]), in: &log)
        #expect(events.count == 2)
    }

    /// Für die Auflösung: laufende und gerade beendete Befunde, ältere fallen weg.
    @Test func keepsRecentlyEndedFindingsForTheResolution() {
        var log = WatchbookFindingLog()
        _ = record(Fixtures.values([load(3, 0.95), load(2, 0.1)]), in: &log)
        #expect(log.findings.count == 1)
        _ = record(Fixtures.values([load(30, 0.1)]), in: &log, from: 300)
        #expect(log.findings.isEmpty)
    }
}
