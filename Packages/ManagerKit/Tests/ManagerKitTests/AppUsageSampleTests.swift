import Foundation
import Testing
@testable import ManagerKit

@Suite struct AppUsageSampleTests {
    private static let end = Date(timeIntervalSince1970: 1_793_959_200)
    private static let safari = RunningApp(pid: 610, bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app",
                                           name: "Safari")

    private static func process(_ pid: Int32, _ name: String, uid: UInt32 = 501, parent: Int32 = 1, cpu: Double?,
                                energy: Double? = nil, disk: Double? = nil, path: String? = nil) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: parent, uid: uid, name: name,
                           cpuLoad: cpu, memoryBytes: 1, diskReadPerSecond: disk, diskWritePerSecond: disk.map { _ in 0 },
                           threadCount: 1, executablePath: path, energyMilliwatts: energy)
    }

    private static func frame(_ processes: [ProcessMeasurement], elapsed: Duration? = .seconds(2),
                              cores: Int = 4) -> TaskManagerFrame {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = processes
        snapshot.cpu = CPULoad(total: 0.5, cores: Array(repeating: CoreLoad(kind: .performance, load: 0.5), count: cores))
        return TaskManagerFrame(snapshot: snapshot, history: SampleHistory(interval: .seconds(1)), elapsed: elapsed)
    }

    private static func make(_ frame: TaskManagerFrame, network: [ProcessKey: Double]? = nil) -> AppUsageSample? {
        AppUsageSample.make(frame: frame, apps: [safari], currentUID: 501, network: network, at: end)
    }

    @Test func appProcessesCountForTheirApp() throws {
        let frame = Self.frame([
            Self.process(610, "Safari", cpu: 0.25, energy: 1_500, disk: 1_000,
                         path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            Self.process(612, "Safari Web Content", parent: 610, cpu: 0.25, energy: 500),
        ])
        let sample = try #require(Self.make(frame, network: [ProcessKey(pid: 612, startTime: 1): 100]))
        let subject = AppUsageSubject(kind: .app, bundleID: "com.apple.Safari", name: "Safari",
                                      bundlePath: "/Applications/Safari.app")
        let totals = try #require(sample.usage.first { $0.0 == subject }?.1)
        // 50 % von 4 Kernen über 2 s = 4 s CPU; 2 W über 2 s = 4 J.
        #expect(totals == AppUsageTotals(cpuSeconds: 4, energyJoules: 4, networkBytes: 200, diskBytes: 2_000))
        #expect(sample.seconds == 2)
        #expect(sample.measuresNetwork)
        #expect(sample.end == Self.end)
    }

    @Test func ownProcessesWithoutAppCountByProgramName() throws {
        let frame = Self.frame([Self.process(2_001, "claude", cpu: 0.125), Self.process(2_002, "claude", cpu: 0.125)])
        let sample = try #require(Self.make(frame))
        #expect(sample.usage.count == 1)
        #expect(sample.usage[0].0 == AppUsageSubject(kind: .process, bundleID: nil, name: "claude", bundlePath: nil))
        #expect(sample.usage[0].1.cpuSeconds == 2)
        #expect(!sample.measuresNetwork)
    }

    @Test func foreignProcessesAreNeverRecorded() throws {
        let frame = Self.frame([Self.process(88, "WindowServer", uid: 88, cpu: 0.5),
                                Self.process(2_001, "claude", cpu: 0.125)])
        let sample = try #require(Self.make(frame))
        #expect(!sample.usage.contains { $0.0.name == "WindowServer" })
    }

    @Test func foreignChildOfAnAppNeitherCountsForTheAppNorAppearsAnywhere() throws {
        let frame = Self.frame([
            Self.process(610, "Safari", cpu: 0.25, path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            Self.process(700, "FremderDienst", uid: 88, parent: 610, cpu: 0.5, energy: 9_000, disk: 5_000),
        ])
        let sample = try #require(Self.make(frame, network: [ProcessKey(pid: 700, startTime: 1): 9_999]))
        #expect(sample.usage.map(\.0.name) == ["Safari"])
        // Nur Safari selbst: 25 % von 4 Kernen über 2 s; Energie nicht gemessen, kein Netz, kein Datenträger.
        #expect(sample.usage[0].1 == AppUsageTotals(cpuSeconds: 2, energyJoules: nil, networkBytes: 0, diskBytes: 0))
    }

    /// Ohne nettop (kein Netz-Abnehmer) und ohne Energiequelle (Intel) bleibt der Verbrauch unbekannt statt 0.
    @Test func unmeasuredNetworkAndEnergyStayUnknown() throws {
        let sample = try #require(Self.make(Self.frame([Self.process(2_001, "claude", cpu: 0.25)])))
        let totals = try #require(sample.usage.first?.1)
        #expect(totals.cpuSeconds == 2)
        #expect(totals.networkBytes == nil)
        #expect(totals.energyJoules == nil)
    }

    @Test func recordedHistoryHoldsNeitherPathsNorForeignNames() throws {
        let frame = Self.frame([
            Self.process(2_001, "tool", cpu: 0.5, path: "/Users/test/geheimes-projekt/bin/tool"),
            Self.process(88, "FremderDienst", uid: 88, cpu: 0.5, energy: 1_000),
        ])
        var history = AppUsageHistory()
        history.add(try #require(Self.make(frame)))
        let text = String(decoding: try history.encoded(), as: UTF8.self)
        #expect(text.contains("tool"))
        #expect(!text.contains("geheimes-projekt"))
        #expect(!text.contains("FremderDienst"))
    }

    @Test func idleProcessesAreSkipped() throws {
        let sample = try #require(Self.make(Self.frame([Self.process(2_005, "zsh", cpu: 0, energy: 0),
                                                        Self.process(2_001, "claude", cpu: 0.1)])))
        #expect(sample.usage.map(\.0.name) == ["claude"])
    }

    @Test func noSampleWithoutElapsedTimeOrProcesses() {
        #expect(Self.make(Self.frame([Self.process(2_001, "claude", cpu: 0.1)], elapsed: nil)) == nil)
        #expect(Self.make(Self.frame([])) == nil)
    }

    /// Untätige Prozesse ändern nichts (#489): Je Takt ordnet der App-Verlauf nur Prozesse mit Verbrauch zu, auch wenn ein
    /// untätiger Elternprozess die Zuordnung zur App trägt.
    @Test func idleProcessesDoNotChangeTheSampleButStillCarryTheOwner() throws {
        let app = Self.process(610, "Safari", cpu: 0, energy: 0, disk: 0,
                               path: "/Applications/Safari.app/Contents/MacOS/Safari")
        let tool = Self.process(700, "tool", parent: 610, cpu: 0.25, energy: 400)
        let idle = (800..<850).map { Self.process(Int32($0), "idle\($0)", cpu: 0, energy: 0, disk: 0) }
        let sample = try #require(Self.make(Self.frame([app, tool] + idle)))
        #expect(sample.usage.map(\.0.name) == ["Safari"])
        #expect(sample.usage[0].1 == AppUsageTotals(cpuSeconds: 2, energyJoules: 0.8, networkBytes: nil, diskBytes: 0))
    }
}
