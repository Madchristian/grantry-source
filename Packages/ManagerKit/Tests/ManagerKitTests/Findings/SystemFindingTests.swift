import Foundation
import Testing
@testable import ManagerKit

@Suite struct SystemFindingTests {
    private typealias F = FindingFixtures
    private static let key = ProcessKey(pid: 100, startTime: 1)

    private func finding(start: Date = F.start, end: Date? = nil, subject: SystemFinding.Subject? = nil,
                         reason: String = "CPU insgesamt länger als 2 min über 80 % ausgelastet.") -> SystemFinding {
        SystemFinding(kind: .systemLoad, tone: .finding, reason: reason, start: start, end: end,
                      evidence: .init(limit: 0.8, peak: 0.9, mean: 0.85), subject: subject)
    }

    /// Dieselbe Art, derselbe Bezug, derselbe Beginn: dieselbe ID – so ersetzt das Ende im Wachbuch den laufenden
    /// Eintrag.
    @Test func identityFollowsKindSubjectAndStart() {
        let running = finding(subject: .process(Self.key, .program("ffmpeg")))
        let ended = finding(end: F.time(600), subject: .process(Self.key, .program("ffmpeg")), reason: "anders")
        #expect(running.id == ended.id)
        #expect(running.id != finding(start: F.time(10), subject: .process(Self.key, .program("ffmpeg"))).id)
        #expect(running.id != finding(subject: .process(ProcessKey(pid: 100, startTime: 2), .program("ffmpeg"))).id)
        #expect(running.id != finding().id)
    }

    @Test func becomesAWatchbookEvent() {
        let subject = SystemFinding.Subject.process(Self.key, .systemProcess("kernel_task"))
        let event = finding(end: F.time(600), subject: subject).watchbookEvent
        #expect(event.kind == .finding)
        #expect(event.type == SystemFinding.Kind.systemLoad.rawValue)
        #expect(event.start == F.start)
        #expect(event.end == F.time(600))
        #expect(event.tone == .finding)
        #expect(event.subject == .systemProcess("kernel_task"))
        #expect(event.summary == "CPU insgesamt länger als 2 min über 80 % ausgelastet.")
        #expect(event.id == finding(subject: subject).id)
    }

    /// PID und Startzeit gehen mit ins Wachbuch (Sprung nach Details, TM-12.6) – nie für Programme anderer Benutzer.
    @Test func processKeyGoesIntoTheWatchbookExceptForOtherAccounts() {
        #expect(finding(subject: .process(Self.key, .program("ffmpeg"))).watchbookEvent.process == Self.key)
        #expect(finding(subject: .process(Self.key, .systemProcess("kernel_task"))).watchbookEvent.process == Self.key)
        #expect(finding(subject: .process(Self.key, .otherAccounts)).watchbookEvent.process == nil)
        #expect(finding(subject: .process(Self.key, nil)).watchbookEvent.process == nil)
        #expect(finding().watchbookEvent.process == nil)
        let ended = finding(subject: .process(Self.key, .program("ffmpeg"))).watchbookEvent.ended(at: F.time(60))
        #expect(ended.process == Self.key)
    }

    /// Volumes und Erweiterungen sind keine Programme: Im Wachbuch bleibt der Verursacher leer.
    @Test func nonProgramSubjectsHaveNoWatchbookSubject() {
        #expect(finding(subject: .volume(name: "Daten")).watchbookEvent.subject == nil)
        #expect(finding(subject: .systemExtension(identifier: "com.example.filter", name: "Filter")).watchbookEvent
            .subject == nil)
        #expect(finding(subject: .app(bundleIdentifier: "com.example.app", name: "Beispiel")).watchbookEvent.subject
            == .program("Beispiel"))
    }

    /// Fremde Texte (Spec §4.5) werden einzeilig und begrenzt.
    @Test func foreignNamesAreSingleLineAndLimited() {
        let long = "Treiber\nzweite Zeile" + String(repeating: "x", count: 500)
        let subject = finding(subject: .volume(name: long)).subject
        guard case .volume(let name) = subject else {
            Issue.record("Bezug fehlt")
            return
        }
        #expect(!name.contains("\n"))
        #expect(name.count <= SystemFinding.maximumNameLength)
    }

    /// Startsatz der Spec §5.1, Schwellen an einer Stelle.
    @Test func standardThresholdsFollowTheSpec() {
        let standard = FindingThresholds.standard
        #expect(standard.rule(for: .systemLoad).limit == 0.8)
        #expect(standard.rule(for: .systemLoad).minimumDuration == 120)
        #expect(standard.rule(for: .processLoad).limit == 0.9)
        #expect(standard.rule(for: .processLoad).minimumDuration == 300)
        #expect(standard.rule(for: .swapGrowth).limit == 2_000_000_000)
        #expect(standard.swapGrowthWindow == 600)
        #expect(standard.rule(for: .thermalState).minimumDuration == 300)
        #expect(standard.rule(for: .sustainedUpload).limit == 5_000_000)
        #expect(standard.rule(for: .sustainedUpload).minimumDuration == 300)
        #expect(standard.rule(for: .batteryDrain).limit == 0.2)
        #expect(standard.rule(for: .memoryPressure).critical == 2)
        #expect(standard.rule(for: .thermalState).critical == 3)
        // Drosselung (§5.3): mindestens mäßiger Druck, unter 70 % Takt bei über 60 % Last für 60 s.
        #expect(standard.rule(for: .throttling).minimumDuration == 60)
        #expect(standard.throttlingClock == 0.7)
        #expect(standard.throttlingLoad == 0.6)
        #expect(standard.throttlingPressure == .moderate)
        // Datenträger (§5.4): über 90 % belegt, SMART-Fehler kritisch, Snapshots älter als 7 Tage.
        #expect(standard.rule(for: .volumeFull).limit == 0.9)
        #expect(standard.rule(for: .smartFailure).critical == 1)
        #expect(standard.rule(for: .staleSnapshots).limit == 7 * 86_400)
    }

    /// Jede Art hat einen eigenen Satz, der die Schwellen nennt.
    @Test(arguments: SystemFinding.Kind.allCases) func reasonsNameTheThresholds(_ kind: SystemFinding.Kind) {
        let reason = FindingRules.reason(for: kind, tone: .finding, subject: nil, thresholds: .standard)
        #expect(!reason.isEmpty)
        #expect(reason.hasSuffix("."))
        #expect(!reason.contains("\n"))
    }
}
