import Foundation
import Testing
@testable import ManagerKit

/// Laufende Befunde des Task-Managers aus den Takten (`FindingTracker`): dieselben Regeln wie das Wachbuch, Pausen als
/// Lücke, 15 Minuten im Speicher.
@Suite struct FindingTrackerTests {
    private typealias F = FindingFixtures

    private static let key = ProcessKey(pid: 2004, startTime: 1)

    /// Vier Kerne; der Prozess belegt `load` aller Kerne (0,25 = ein voller Kern).
    private static func snapshot(load: Double, pressure: MemoryStatus.Pressure = .normal) -> TaskManagerSnapshot {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.3, cores: Array(repeating: CoreLoad(kind: .performance, load: 0.3), count: 4))
        snapshot.memory = MemoryStatus(physicalBytes: 16, usedBytes: 6, swapUsedBytes: nil, swapTotalBytes: nil,
                                       pressure: pressure, processCount: 2)
        snapshot.processes = [
            ProcessMeasurement(key: key, parentPID: 1, uid: 501, name: "photoanalysisd", cpuLoad: load, memoryBytes: 1,
                               diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: 1),
            ProcessMeasurement(key: ProcessKey(pid: 3000, startTime: 1), parentPID: 1, uid: 501, name: "ruhig",
                               cpuLoad: 0.01, memoryBytes: 1, diskReadPerSecond: nil, diskWritePerSecond: nil,
                               threadCount: 1),
        ]
        return snapshot
    }

    /// Takte im Abstand von 1 s ab `offset`.
    private static func record(_ tracker: inout FindingTracker, seconds: ClosedRange<Int>, load: Double,
                               pressure: MemoryStatus.Pressure = .normal, thermal: ProcessInfo.ThermalState = .nominal) {
        for second in seconds {
            tracker.record(snapshot(load: load, pressure: pressure), at: F.time(Double(second)), thermalState: thermal,
                           currentUID: 501)
        }
    }

    private var processMinimum: Int { Int(F.thresholds.processLoad.minimumDuration) }

    @Test func sustainedProcessLoadBecomesAFinding() {
        var tracker = FindingTracker()
        Self.record(&tracker, seconds: 0...processMinimum, load: 0.25)
        let finding = tracker.findings.first
        #expect(tracker.findings.count == 1)
        #expect(finding?.kind == .processLoad)
        #expect(finding?.subject == .process(Self.key, .program("photoanalysisd")))
        #expect(finding?.isOngoing == true)
    }

    @Test func shortPeakIsNoFinding() {
        var tracker = FindingTracker()
        Self.record(&tracker, seconds: 0...(processMinimum / 2), load: 0.25)
        #expect(tracker.findings.isEmpty)
    }

    /// Nach dem Ende der Last und der Ruhezeit läuft der Befund nicht mehr.
    @Test func findingEndsAfterTheQuietDuration() {
        var tracker = FindingTracker()
        Self.record(&tracker, seconds: 0...processMinimum, load: 0.25)
        let quiet = Int(F.thresholds.processLoad.quietDuration)
        Self.record(&tracker, seconds: (processMinimum + 1)...(processMinimum + quiet + 1), load: 0.01)
        #expect(tracker.findings.isEmpty)
    }

    /// Eine Pause (verdeckter Task-Manager) beginnt keinen Befund: Die Mindestdauer zählt nach der Lücke neu.
    @Test func pauseIsAGap() {
        var tracker = FindingTracker()
        let half = processMinimum / 2
        Self.record(&tracker, seconds: 0...half, load: 0.25)
        Self.record(&tracker, seconds: (half + 120)...(processMinimum + 120), load: 0.25)
        #expect(tracker.findings.isEmpty)
    }

    /// Speicherdruck und Thermik kommen aus denselben Takten.
    @Test func memoryPressureAndThermalStateUseTheRules() {
        var tracker = FindingTracker()
        let minimum = Int(F.thresholds.thermalState.minimumDuration)
        Self.record(&tracker, seconds: 0...minimum, load: 0.01, pressure: .critical, thermal: .serious)
        #expect(tracker.findings.map(\.kind) == [.memoryPressure, .thermalState])
        #expect(tracker.findings.first?.tone == .critical)
    }

    /// Ältere Takte als `span` entfallen; ein Befund, der nur dort lag, ist vorbei.
    @Test func keepsOnlyTheSpan() {
        var tracker = FindingTracker(span: 600)
        Self.record(&tracker, seconds: 0...processMinimum, load: 0.25)
        #expect(!tracker.findings.isEmpty)
        // Lange Lücke, dann ruhig: Die alte Last liegt außerhalb des Fensters.
        Self.record(&tracker, seconds: 2_000...2_010, load: 0.01)
        #expect(tracker.findings.isEmpty)
    }

    /// Der Filter auf Prozesse über der Schwelle ändert das Ergebnis der Regel nicht.
    @Test func filteredSamplesMatchTheFullList() {
        let loads: [Double] = (0...400).map { $0 % 97 < 80 ? 0.25 : 0.2 }
        let snapshots = loads.enumerated().map { (F.time(Double($0.offset)), Self.snapshot(load: $0.element)) }
        let full = snapshots.map { ProcessLoadSample(time: $0.0, snapshot: $0.1, currentUID: 501) }
        let filtered = snapshots.map {
            ProcessLoadSample(time: $0.0, snapshot: $0.1, currentUID: 501, above: F.thresholds.processLoad.limit)
        }
        #expect(filtered.allSatisfy { ($0.processes?.count ?? 0) <= 1 })
        #expect(FindingRules.processFindings(in: filtered) == FindingRules.processFindings(in: full))
    }

    // MARK: Drosselung (TM-14.2)

    private static func throttled(at second: Int) -> ThrottlingSample {
        ThrottlingSample(time: F.time(Double(second)), pressure: .moderate,
                         performanceClusters: [.init(load: 0.9, clockShare: 0.5)])
    }

    /// Sensor-Messungen kommen außerhalb des Takts an und ergeben denselben laufenden Befund.
    @Test func throttlingFromSensorReadings() {
        var tracker = FindingTracker()
        let minimum = Int(F.thresholds.throttling.minimumDuration)
        for second in stride(from: 0, through: minimum, by: 2) { tracker.record(Self.throttled(at: second)) }
        #expect(tracker.findings.map(\.kind) == [.throttling])
        Self.record(&tracker, seconds: (minimum + 1)...(minimum + 2), load: 0.01)
        #expect(tracker.findings.map(\.kind) == [.throttling])
    }

    /// Ohne frische Sensor-Messung (Helper aus, Tab gewechselt) läuft keine Drosselung weiter – nicht gemessen heißt
    /// nicht „läuft noch“.
    @Test func throttlingWithoutFreshReadingIsNotOngoing() {
        var tracker = FindingTracker()
        let minimum = Int(F.thresholds.throttling.minimumDuration)
        for second in stride(from: 0, through: minimum, by: 2) { tracker.record(Self.throttled(at: second)) }
        let stale = minimum + Int(F.thresholds.maximumGap) + 1
        Self.record(&tracker, seconds: (minimum + 1)...stale, load: 0.01)
        #expect(tracker.findings.isEmpty)
    }

    // MARK: Datenträger (TM-15.5)

    private static func failingDisk(_ status: SMARTStatus = .failing) -> VolumeInventory {
        VolumeInventory(devices: [StorageDevice(id: "disk0", name: "SSD", smartStatus: status)], localSnapshots: nil,
                        isComplete: true)
    }

    /// Das Inventar kommt nach einem Scan an, nicht mit dem Takt: Datenträger-Befunde bleiben über Takte bestehen,
    /// kritische zuerst.
    @Test func storageFindingsOutliveTicks() {
        var tracker = FindingTracker()
        tracker.record(Self.failingDisk(), at: F.start)
        #expect(tracker.findings.map(\.kind) == [.smartFailure])
        Self.record(&tracker, seconds: 0...processMinimum, load: 0.25)
        #expect(tracker.findings.map(\.kind) == [.smartFailure, .processLoad])
        Self.record(&tracker, seconds: 2_000...2_001, load: 0.01)
        #expect(tracker.findings.map(\.kind) == [.smartFailure])
    }

    /// Eine neue Prüfung setzt den Befund fort (gleiche ID) oder beendet ihn.
    @Test func storageFindingsFollowTheNextInventory() {
        var tracker = FindingTracker()
        tracker.record(Self.failingDisk(), at: F.start)
        let first = tracker.findings
        tracker.record(Self.failingDisk(), at: F.time(900))
        #expect(tracker.findings == first)
        tracker.record(Self.failingDisk(.verified), at: F.time(1_800))
        #expect(tracker.findings.isEmpty)
    }
}
