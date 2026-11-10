import Foundation
import GrantryShared
import Testing
@testable import ManagerKit

@Suite struct WatchbookModelTests {
    private static let time = WatchbookFixtures.dayStart.addingTimeInterval(3_600)

    private static func process(_ pid: Int32, _ name: String, uid: UInt32 = 501, cpu: Double?, memory: UInt64?,
                                path: String? = nil) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: 1, uid: uid, name: name, cpuLoad: cpu,
                           memoryBytes: memory, diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: 1,
                           executablePath: path)
    }

    // MARK: Messgrößen

    @Test func newValuesAreNotMeasured() {
        let values = WatchbookValues()
        #expect(WatchbookMetric.allCases.allSatisfy { values[$0] == nil })
        #expect(values.isEmpty)
    }

    /// Ungültige Werte gelten als nicht gemessen, nie als 0.
    @Test func invalidValuesAreNotMeasured() {
        var values = WatchbookValues()
        values[.cpuTotal] = .nan
        values[.diskRead] = -1
        values[.power] = .infinity
        #expect(values[.cpuTotal] == nil && values[.diskRead] == nil && values[.power] == nil)
        values[.swapUsed] = 0
        #expect(values[.swapUsed] == 0)
    }

    // MARK: Punkt aus einem Takt

    @Test func pointTakesTotalsFromTheSnapshot() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.4, cores: [
            CoreLoad(kind: .performance, load: 0.5), CoreLoad(kind: .performance, load: 0.75),
            CoreLoad(kind: .efficiency, load: 0.2), CoreLoad(kind: .efficiency, load: nil),
        ])
        snapshot.memory = MemoryStatus(
            physicalBytes: 16 << 30, usedBytes: 9 << 30, swapUsedBytes: 1 << 30, swapTotalBytes: 2 << 30,
            pressure: .warning, processCount: 3,
            components: MemoryComponents(appBytes: 5 << 30, wiredBytes: 2 << 30, compressedBytes: 2 << 30,
                                         cachedBytes: 1 << 30))
        snapshot.drives = [DriveThroughput(id: "disk0", name: "SSD", readPerSecond: 1_000, writePerSecond: 500),
                           DriveThroughput(id: "disk4", name: "USB", readPerSecond: 200, writePerSecond: nil)]
        snapshot.interfaces = [
            InterfaceThroughput(name: "en0", receivedPerSecond: 3_000, sentPerSecond: 700, addresses: ["192.168.1.2"]),
            InterfaceThroughput(name: "lo0", receivedPerSecond: 9_999, sentPerSecond: 9_999, addresses: ["127.0.0.1"]),
        ]
        snapshot.gpu = GPULoadReading(utilization: 0.1, usedMemoryBytes: nil)
        snapshot.battery = BatteryReading(charge: 0.55, source: .battery)
        let point = WatchbookPoint(time: Self.time, snapshot: snapshot, currentUID: 501, thermalState: .serious,
                                   power: WatchbookPower(total: 7.5, cpu: nil, gpu: nil, neuralEngine: nil))
        let values = point.values
        #expect(values[.cpuTotal] == 0.4)
        #expect(values[.cpuPerformance] == 0.625)
        #expect(values[.cpuEfficiency] == 0.2)
        #expect(values[.memoryUsed] == Double(9 << 30))
        #expect(values[.memoryCompressed] == Double(2 << 30))
        #expect(values[.swapUsed] == Double(1 << 30))
        #expect(values[.memoryPressure] == 1)
        #expect(values[.diskRead] == 1_200)
        #expect(values[.diskWrite] == 500)
        // Loopback zählt nicht zum Netz.
        #expect(values[.networkReceived] == 3_000)
        #expect(values[.networkSent] == 700)
        #expect(values[.gpu] == 0.1)
        #expect(values[.thermalState] == 2)
        #expect(values[.batteryCharge] == 0.55)
        #expect(values[.externalPower] == 0)
        #expect(values[.power] == 7.5)
        #expect(point.time == Self.time)
    }

    /// Was der Takt nicht gemessen hat, bleibt leer – nie 0 (Spec §5.1).
    @Test func pointWithoutMeasurementsStaysEmpty() {
        let point = WatchbookPoint(time: Self.time, snapshot: TaskManagerSnapshot(), currentUID: 501, thermalState: nil,
                                   power: nil)
        #expect(point.values.isEmpty)
        #expect(point.cpuConsumers.isEmpty && point.memoryConsumers.isEmpty)
    }

    @Test func pointWithUnmeasuredRatesStaysEmptyForThem() {
        var snapshot = TaskManagerSnapshot()
        snapshot.drives = [DriveThroughput(id: "disk0", name: "SSD", readPerSecond: nil, writePerSecond: nil)]
        snapshot.interfaces = [InterfaceThroughput(name: "en0", receivedPerSecond: nil, sentPerSecond: nil,
                                                   addresses: ["192.168.1.2"])]
        snapshot.cpu = CPULoad(total: nil, cores: [CoreLoad(kind: .unknown, load: 0.5)])
        let values = WatchbookPoint(time: Self.time, snapshot: snapshot, currentUID: 501, thermalState: nil,
                                    power: nil).values
        #expect(values[.diskRead] == nil && values[.diskWrite] == nil)
        #expect(values[.networkReceived] == nil && values[.networkSent] == nil)
        #expect(values[.cpuTotal] == nil && values[.cpuPerformance] == nil && values[.cpuEfficiency] == nil)
    }

    // MARK: Größte Verbraucher

    @Test func consumersAreTheThreeLargestPerSubject() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [
            Self.process(10, "Xcode", cpu: 0.05, memory: 3_000),
            Self.process(11, "Safari Web Content", cpu: 0.04, memory: 500),
            Self.process(12, "Safari Web Content", cpu: 0.04, memory: 600),
            Self.process(13, "claude", cpu: 0.01, memory: 4_000),
            Self.process(14, "mds_stores", uid: 0, cpu: 0.02, memory: 100),
            Self.process(15, "idle", cpu: nil, memory: nil),
        ]
        let point = WatchbookPoint(time: Self.time, snapshot: snapshot, currentUID: 501, thermalState: nil,
                                   power: nil)
        #expect(point.cpuConsumers == [
            WatchbookConsumer(subject: .program("Safari Web Content"), value: 0.08),
            WatchbookConsumer(subject: .program("Xcode"), value: 0.05),
            WatchbookConsumer(subject: .systemProcess("mds_stores"), value: 0.02),
        ])
        #expect(point.memoryConsumers == [
            WatchbookConsumer(subject: .program("claude"), value: 4_000),
            WatchbookConsumer(subject: .program("Xcode"), value: 3_000),
            WatchbookConsumer(subject: .program("Safari Web Content"), value: 1_100),
        ])
    }

    /// Programme anderer Benutzer heißen „Andere Konten“ und zählen zusammen (Spec §4.5); Systemkonten unter 500
    /// behalten ihren Namen.
    @Test func otherUsersProgramsBecomeOtherAccounts() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [
            Self.process(20, "geheimes-projekt", uid: 502, cpu: 0.25, memory: 10),
            Self.process(21, "noch-eins", uid: 503, cpu: 0.125, memory: 10),
            Self.process(22, "nobody-dienst", uid: UInt32(bitPattern: -2), cpu: 0.125, memory: 10),
            Self.process(23, "WindowServer", uid: 88, cpu: 0.05, memory: 10),
        ]
        let point = WatchbookPoint(time: Self.time, snapshot: snapshot, currentUID: 501, thermalState: nil,
                                   power: nil)
        #expect(point.cpuConsumers.map(\.subject) == [.otherAccounts, .systemProcess("WindowServer")])
        #expect(point.cpuConsumers.first?.value == 0.5)
        #expect(WatchbookSubject.otherAccounts.name == nil)
    }

    @Test func consumerNamesAreSingleLineWithoutPathAndLimited() {
        let subject = WatchbookSubject(processNamed: "  /Users/anna/bin/werk\tzeug\n", uid: 501, currentUID: 501)
        #expect(subject == .program("werk zeug"))
        let long = WatchbookSubject(processNamed: String(repeating: "a", count: 300), uid: 0, currentUID: 501)
        #expect(long?.name?.count == WatchbookSubject.maximumNameLength)
        #expect(WatchbookSubject(processNamed: " \n", uid: 501, currentUID: 501) == nil)
        #expect(WatchbookSubject(processNamed: "", uid: 777, currentUID: 501) == .otherAccounts)
    }

    @Test func consumersTieBreakByNameForAStableOrder() {
        let processes = [Self.process(1, "b", cpu: 0.1, memory: nil), Self.process(2, "a", cpu: 0.1, memory: nil)]
        let ranked = WatchbookConsumer.largest(processes, currentUID: 501).cpu
        #expect(ranked.map(\.subject) == [.program("a"), .program("b")])
    }

    /// Der schnelle Weg für sichtbares ASCII ergibt dieselben Namen wie die volle Bereinigung.
    @Test func plainNamesMatchTheFullCleanup() {
        for name in ["Xcode", "/usr/libexec/trustd", "com.apple.WebKit.WebContent", "a/b/", "///", "x-y_z.1~",
                     String(repeating: "q", count: 100), String(repeating: "r", count: 64)] {
            let full = DisplayText.singleLine(DisplayText.singleLine(name).split(separator: "/").last.map(String.init)
                ?? "").prefix(WatchbookSubject.maximumNameLength)
            #expect(WatchbookSubject(processNamed: name, uid: 501, currentUID: 501)?.name
                ?? "" == String(full), "\(name)")
        }
    }

    /// Ein Name, der sich erst durch die Bereinigung gleicht, zählt mit seinen Prozessen zusammen.
    @Test func namesThatCleanUpAlikeCountTogether() {
        let processes = [Self.process(1, "werk zeug", cpu: 0.1, memory: 10),
                         Self.process(2, "werk\tzeug", cpu: 0.2, memory: 20)]
        let ranked = WatchbookConsumer.largest(processes, currentUID: 501)
        #expect(ranked.cpu.map(\.subject) == [.program("werk zeug")])
        #expect(ranked.cpu.first.map { abs($0.value - 0.3) < 1e-12 } == true)
        #expect(ranked.memory.first?.value == 30)
    }

    // MARK: Ereignisse

    @Test func eventTextsAreSingleLineAndLimited() {
        let event = WatchbookEvent(kind: .change, type: "autostart/neu dazu", start: Self.time, end: Self.time,
                                   tone: nil, subject: nil,
                                   summary: "Erste Zeile\nzweite\tZeile" + String(repeating: "x", count: 1_000))
        #expect(event.type == "autostart_neu_dazu")
        #expect(!event.summary.contains("\n") && !event.summary.contains("\t"))
        #expect(event.summary.hasPrefix("Erste Zeile zweite Zeile"))
        #expect(event.summary.count == WatchbookEvent.maximumSummaryLength)
    }

    @Test func eventOverlapsItsRangeAndOngoingFindingsReachToTheEnd() {
        let start = Self.time
        let instant = WatchbookFixtures.event(.system, start: start, end: start)
        #expect(instant.overlaps(start..<start.addingTimeInterval(1)))
        #expect(!instant.overlaps(start.addingTimeInterval(1)..<start.addingTimeInterval(2)))
        let ongoing = WatchbookFixtures.event(start: start, end: nil)
        #expect(ongoing.overlaps(start.addingTimeInterval(86_400)..<start.addingTimeInterval(90_000)))
        #expect(!ongoing.overlaps(start.addingTimeInterval(-10)..<start))
        let ended = ongoing.ended(at: start.addingTimeInterval(60))
        #expect(ended.id == ongoing.id && ended.end == start.addingTimeInterval(60))
        #expect(!ended.overlaps(start.addingTimeInterval(61)..<start.addingTimeInterval(62)))
    }

    /// Schnittstelle zum Befund-Modell (TM-12.1): Ein Befund liefert seinen Wachbuch-Eintrag.
    @Test func findingsEnterThroughTheEventInterface() {
        struct Finding: WatchbookEventConvertible {
            let watchbookEvent: WatchbookEvent
        }
        let event = WatchbookFixtures.event(start: Self.time, end: nil)
        #expect(Finding(watchbookEvent: event).watchbookEvent == event)
    }

    // MARK: Tage

    @Test func daysAreUTCDaysIndependentOfTheTimeZone() throws {
        let day = WatchbookFixtures.day
        #expect(day.index == 20_764)
        #expect(day.fileName == "2026-11-07.watchbook")
        #expect(WatchbookDay(fileName: "2026-11-07.watchbook") == day)
        #expect(WatchbookDay(containing: day.start.addingTimeInterval(86_399.9)) == day)
        #expect(WatchbookDay(containing: day.start.addingTimeInterval(86_400)) == WatchbookDay(index: 20_765))
        #expect(WatchbookDay(containing: day.start.addingTimeInterval(-0.1)) == WatchbookDay(index: 20_763))
        #expect(day.end == day.start.addingTimeInterval(86_400))
    }

    @Test func onlyExactDayFileNamesAreRecognized() {
        for name in ["2026-02-30.watchbook", "2026-11-7.watchbook", "2026-11-07.watchbook.tmp", "x.watchbook",
                     "2026-11-07.unreadable-20261107T101010.watchbook", ".2026-11-07.watchbook.ABC"] {
            #expect(WatchbookDay(fileName: name) == nil, "\(name)")
        }
        #expect(WatchbookDay(fileName: "1970-01-01.watchbook") == WatchbookDay(index: 0))
    }
}
