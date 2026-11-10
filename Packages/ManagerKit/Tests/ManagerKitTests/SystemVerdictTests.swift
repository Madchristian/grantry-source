import Foundation
import Testing
@testable import ManagerKit

/// Urteil der Lage- und Zustandszeile (Gestaltung „Lagebild“, Entscheidung E9): nur aus laufenden Befunden
/// (`FindingRules`), nie aus einem einzelnen Messwert.
@Suite struct SystemVerdictTests {
    private typealias F = FindingFixtures

    private static let key = ProcessKey(pid: 2004, startTime: 1)

    private static func memory(_ pressure: MemoryStatus.Pressure) -> MemoryStatus {
        MemoryStatus(physicalBytes: 16, usedBytes: 6, swapUsedBytes: nil, swapTotalBytes: nil, pressure: pressure,
                     processCount: 1)
    }

    /// Vier Kerne; der Prozess belegt `load` aller Kerne.
    private static func snapshot(load: Double, pressure: MemoryStatus.Pressure = .normal) -> TaskManagerSnapshot {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.3, cores: Array(repeating: CoreLoad(kind: .performance, load: 0.3), count: 4))
        snapshot.memory = memory(pressure)
        snapshot.processes = [ProcessMeasurement(key: key, parentPID: 1, uid: 501, name: "photoanalysisd", cpuLoad: load,
                                                 memoryBytes: 1, diskReadPerSecond: nil, diskWritePerSecond: nil,
                                                 threadCount: 1)]
        return snapshot
    }

    private static func finding(_ kind: SystemFinding.Kind, tone: SystemFinding.Tone = .finding,
                                subject: SystemFinding.Subject? = nil, end: Date? = nil) -> SystemFinding {
        SystemFinding(kind: kind, tone: tone,
                      reason: FindingRules.reason(for: kind, tone: tone, subject: subject, thresholds: F.thresholds),
                      start: F.start, end: end, evidence: .init(limit: 0, peak: 1, mean: 1), subject: subject)
    }

    private static let processFinding = finding(.processLoad, subject: .process(key, .program("photoanalysisd")))

    private func verdict(_ snapshot: TaskManagerSnapshot, _ findings: [SystemFinding],
                         thermal: ProcessInfo.ThermalState = .nominal, lowPower: Bool = false) -> SystemVerdict {
        var snapshot = snapshot
        snapshot.thermal = ThermalCondition(state: thermal, isLowPowerModeEnabled: lowPower)
        return SystemVerdictPresentation.verdict(snapshot: snapshot, findings: findings, interval: "1 s", uptime: 60)
    }

    @Test func calmWithoutFindings() {
        let result = verdict(Self.snapshot(load: 0.05), [])
        #expect(result.level == .calm)
        #expect(result.title == "Ruhig")
        #expect(result.processFindings.isEmpty)
        #expect(result.items.map(\.tone) == [.positive, .positive])
    }

    /// Titel aus der Zahl der Prozesse, Grund wörtlich aus `FindingRules` – keine eigenen Schwellen oder Texte.
    @Test func processFindingUsesTheRuleText() {
        let result = verdict(Self.snapshot(load: 0.25), [Self.processFinding])
        #expect(result.level == .finding)
        #expect(result.title == "1 Prozess auffällig")
        #expect(result.processFindings.map(\.name) == ["photoanalysisd"])
        #expect(result.reason == Self.processFinding.reason)
        #expect(result.processFindings.first?.reason == Self.processFinding.reason)
        #expect(result.processFindings.first?.cpuLoad == 0.25)
    }

    /// Beendete Befunde und Prozesse, die nicht mehr laufen, zählen nicht.
    @Test func endedFindingsAndGoneProcessesAreIgnored() {
        let ended = Self.finding(.memoryPressure, end: F.time(60))
        let gone = Self.finding(.processLoad, subject: .process(ProcessKey(pid: 9, startTime: 1), nil))
        let result = verdict(Self.snapshot(load: 0.25), [ended, gone])
        #expect(result.level == .finding)
        #expect(result.processFindings.isEmpty)
    }

    /// Erhöhter Speicherdruck ohne Befund ist noch kein Bernstein; mit Befund auffällig, kritisch zuerst.
    @Test func memoryAndThermalChipsTurnAmberOnlyWithAFinding() {
        let pending = verdict(Self.snapshot(load: 0, pressure: .warning), [], thermal: .fair)
        #expect(pending.level == .calm)
        #expect(pending.items.map(\.tone) == [.neutral, .neutral])

        let warning = verdict(Self.snapshot(load: 0, pressure: .warning), [Self.finding(.memoryPressure)])
        #expect(warning.level == .finding)
        #expect(warning.title == "Speicher wird knapp")
        #expect(warning.items.first?.tone == .warning)

        let critical = verdict(Self.snapshot(load: 0.25, pressure: .critical),
                               [Self.processFinding, Self.finding(.memoryPressure, tone: .critical)])
        #expect(critical.level == .critical)
        #expect(critical.title == "Speicher kritisch")
        #expect(critical.items.map(\.tone) == [.warning, .critical, .positive])

        let warm = verdict(Self.snapshot(load: 0), [Self.finding(.thermalState)], thermal: .serious)
        #expect(warm.title == "Mac wird warm")
        #expect(warm.reason == Self.finding(.thermalState).reason)
    }

    /// Befunde ohne eigenen Chip (Upload, Datenträger …) erscheinen als Chip mit ihrem Titel.
    @Test func otherFindingsGetAChip() {
        let result = verdict(Self.snapshot(load: 0), [Self.finding(.sustainedUpload)])
        #expect(result.title == "Anhaltender Upload")
        #expect(result.items.last == SystemVerdict.Item(text: "Anhaltender Upload", tone: .warning))
    }

    /// Datenträger-Befunde (TM-15.5) in der Lagezeile: SMART-Fehler kritisch und führend, die anderen als Chip.
    @Test func storageFindingsReachTheVerdictBar() {
        let smart = Self.finding(.smartFailure, tone: .critical, subject: .volume(name: "APPLE SSD"))
        let full = Self.finding(.volumeFull, subject: .volume(name: "Macintosh HD"))
        let snapshots = Self.finding(.staleSnapshots, subject: .volume(name: "Macintosh HD"))
        let result = verdict(Self.snapshot(load: 0), [full, snapshots, smart], lowPower: true)
        #expect(result.level == .critical)
        #expect(result.title == "SMART-Fehler")
        #expect(result.reason == smart.reason)
        #expect(Array(result.items.suffix(3)) == [SystemVerdict.Item(text: "Volume fast voll", tone: .warning),
                                                  SystemVerdict.Item(text: "Alte lokale Snapshots", tone: .warning),
                                                  SystemVerdict.Item(text: "SMART-Fehler", tone: .critical)])
        let quiet = verdict(Self.snapshot(load: 0), [full])
        #expect(quiet.level == .finding)
        #expect(quiet.title == "Volume fast voll")
        #expect(quiet.reason == "„Macintosh HD“ ist zu mehr als 90 % belegt.")
    }

    @Test func quietTextNamesTheRuleThresholds() {
        #expect(SystemVerdictPresentation.quietProcessesText() == "Kein Prozess belegt länger als 5 min mehr als 90 % eines Kerns.")
    }

    @Test func factsComeFromTheStatusLine() {
        let result = verdict(Self.snapshot(load: 0), [])
        #expect(result.facts.hasPrefix("Takt 1 s · 1 Prozesse"))
    }

    // MARK: Thermik ohne Helper und Energiesparmodus (TM-14.2)

    /// Der thermische Zustand kommt mit dem Takt (`TaskManagerSnapshot.thermal`); ungelesen gibt es keinen Chip.
    @Test func thermalChipNeedsAMeasuredState() {
        let result = SystemVerdictPresentation.verdict(snapshot: Self.snapshot(load: 0), findings: [], interval: "1 s",
                                                       uptime: 60)
        #expect(result.items.map(\.text) == ["Speicherdruck normal"])
    }

    /// Energiesparmodus als Grund in Lagezeile und Chip: neutral, kein Befund.
    @Test func lowPowerModeIsAReasonInLineAndChip() {
        let result = verdict(Self.snapshot(load: 0.05), [], lowPower: true)
        #expect(result.level == .calm)
        #expect(result.items.last == SystemVerdict.Item(text: "Energiesparmodus", tone: .neutral))
        #expect(result.reason.hasSuffix("Der Energiesparmodus ist an und senkt Takt und Leistung."))
        #expect(!verdict(Self.snapshot(load: 0.05), []).items.contains { $0.text == "Energiesparmodus" })
    }

    /// Bei Last- und Thermikbefunden nennt die Lagezeile den Energiesparmodus als Grund mit.
    @Test func lowPowerModeExplainsThrottling() {
        let throttling = Self.finding(.throttling)
        let result = verdict(Self.snapshot(load: 0), [throttling], thermal: .fair, lowPower: true)
        #expect(result.title == "Mac drosselt")
        #expect(result.reason.hasPrefix(throttling.reason))
        #expect(result.reason.hasSuffix("Der Energiesparmodus ist an und senkt Takt und Leistung."))
        #expect(result.items.contains(SystemVerdict.Item(text: "Mac drosselt", tone: .warning)))
        // Für Speicherdruck ist der Energiesparmodus kein Grund.
        let memory = verdict(Self.snapshot(load: 0, pressure: .warning), [Self.finding(.memoryPressure)], lowPower: true)
        #expect(memory.reason == Self.finding(.memoryPressure).reason)
    }
}

