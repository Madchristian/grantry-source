import Foundation
import Testing
@testable import ManagerKit

/// Dauerlast je Prozess (Spec 2026-11-08 §5.1): über 90 % eines Kerns für 5 min; ein Prozess ist PID plus Startzeit.
@Suite struct ProcessLoadRuleTests {
    private typealias F = FindingFixtures

    private static let encoder = ProcessKey(pid: 100, startTime: 1)
    /// Dieselbe PID, später neu vergeben.
    private static let reused = ProcessKey(pid: 100, startTime: 2)
    private static let subject = WatchbookSubject.program("ffmpeg")

    private var minimum: TimeInterval { F.thresholds.rule(for: .processLoad).minimumDuration }
    private var quiet: TimeInterval { F.thresholds.rule(for: .processLoad).quietDuration }

    /// Je Takt die gemessenen Prozesse; `nil` = Prozessliste nicht gemessen.
    private func samples(_ takts: [[ProcessKey: Double]?], from offset: TimeInterval = 0) -> [ProcessLoadSample] {
        takts.enumerated().map { index, loads in
            ProcessLoadSample(time: F.time(offset + Double(index) * F.step), processes: loads?.mapValues {
                ProcessLoad(coreShare: $0, subject: Self.subject)
            })
        }
    }

    private func repeated(_ loads: [ProcessKey: Double]?, _ count: Int) -> [[ProcessKey: Double]?] {
        Array(repeating: loads, count: count)
    }

    private func findings(_ samples: [ProcessLoadSample]) -> [SystemFinding] {
        FindingRules.processFindings(in: samples, thresholds: F.thresholds)
    }

    @Test func processAboveTheLimitForTheMinimumDurationIsAFinding() {
        let result = findings(samples(repeated([Self.encoder: 0.91], F.count(spanning: minimum))))
        #expect(result.count == 1)
        #expect(result.first?.kind == .processLoad)
        #expect(result.first?.subject == .process(Self.encoder, Self.subject))
        #expect(result.first?.reason.hasPrefix("ffmpeg") == true)
        #expect(result.first?.start == F.start)
    }

    @Test func processAtTheLimitIsNoFinding() {
        #expect(findings(samples(repeated([Self.encoder: 0.9], F.count(spanning: minimum * 2)))).isEmpty)
    }

    @Test func justShortOfTheMinimumDurationIsNoFinding() {
        #expect(findings(samples(repeated([Self.encoder: 2], F.count(spanning: minimum) - 1))).isEmpty)
    }

    /// Dieselbe PID mit anderer Startzeit ist ein anderer Prozess: Zwei kurze Läufe ergeben keinen Befund.
    @Test func reusedPIDIsAnotherProcess() {
        let half = F.count(spanning: minimum / 2) + 2
        let takts = repeated([Self.encoder: 1], half) + repeated([Self.reused: 1], half)
        #expect(findings(samples(takts)).isEmpty)
    }

    /// Endet der Prozess, zählt das als Ruhe: Sein Befund endet nach der Ruhezeit, der Nachfolger mit derselben PID
    /// erbt ihn nicht.
    @Test func endedProcessEndsItsFinding() {
        let active = F.count(spanning: minimum)
        let takts = repeated([Self.encoder: 1], active) + repeated([Self.reused: 1], F.count(spanning: quiet))
        let result = findings(samples(takts))
        #expect(result.count == 1)
        #expect(result.first?.subject == .process(Self.encoder, Self.subject))
        #expect(result.first?.end == F.time(Double(active - 1) * F.step))
    }

    @Test func unmeasuredProcessListDoesNotStartAFinding() {
        let half = F.count(spanning: minimum / 2) + 1
        let takts = repeated([Self.encoder: 1], half) + [nil] + repeated([Self.encoder: 1], half)
        #expect(findings(samples(takts)).isEmpty)
    }

    /// Programme anderer Benutzer bleiben ohne Namen (Spec §4.5).
    @Test func otherAccountsStayNameless() {
        let points = (0..<F.count(spanning: minimum)).map { index in
            ProcessLoadSample(time: F.time(Double(index) * F.step),
                              processes: [Self.encoder: ProcessLoad(coreShare: 1, subject: .otherAccounts)])
        }
        let finding = findings(points).first
        #expect(finding?.subject == .process(Self.encoder, .otherAccounts))
        #expect(finding?.reason.contains("ffmpeg") == false)
        #expect(finding?.reason.hasPrefix("Ein Prozess eines anderen Kontos") == true)
    }

    @Test func sampleFromATaskManagerSnapshot() {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.3, cores: Array(repeating: CoreLoad(kind: .performance, load: 0.3), count: 4))
        snapshot.processes = [
            ProcessMeasurement(key: Self.encoder, parentPID: 1, uid: 501, name: "/opt/bin/ffmpeg", cpuLoad: 0.25,
                               memoryBytes: 1, diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: 1),
            ProcessMeasurement(key: Self.reused, parentPID: 1, uid: 502, name: "secret", cpuLoad: nil,
                               memoryBytes: 1, diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: 1),
        ]
        let sample = ProcessLoadSample(time: F.start, snapshot: snapshot, currentUID: 501)
        // 25 % aller vier Kerne = ein voller Kern.
        #expect(sample.processes?[Self.encoder] == ProcessLoad(coreShare: 1, subject: .program("ffmpeg")))
        #expect(sample.processes?[Self.reused] == ProcessLoad(coreShare: nil, subject: .otherAccounts))

        snapshot.unavailable = [.processes]
        #expect(ProcessLoadSample(time: F.start, snapshot: snapshot, currentUID: 501).processes == nil)
        snapshot.unavailable = []
        snapshot.cpu = nil
        #expect(ProcessLoadSample(time: F.start, snapshot: snapshot, currentUID: 501).processes == nil)
    }
}
