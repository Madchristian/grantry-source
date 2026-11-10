import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@Suite struct SevereFindingAlertsTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Die Einstellung, wie der Melder sie je Prüfung liest.
    private final class Setting: Sendable {
        private let value = Mutex(true)
        var isOn: Bool {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    private let setting = Setting()

    private static func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private static func finding(_ kind: SystemFinding.Kind, tone: SystemFinding.Tone = .finding, at offset: TimeInterval = 0,
                                end: TimeInterval? = nil, peak: Double = 1,
                                subject: SystemFinding.Subject? = nil) -> SystemFinding {
        SystemFinding(kind: kind, tone: tone,
                      reason: FindingRules.reason(for: kind, tone: tone, subject: subject, thresholds: .standard),
                      start: time(offset), end: end.map(time), evidence: .init(limit: 0, peak: peak, mean: peak),
                      subject: subject)
    }

    /// Prüft wie der Recorder und zeichnet die fälligen Mitteilungen auf, ohne Tasks abzuwarten.
    private final class Reviewer {
        var alerts: SevereFindingAlerts
        private(set) var all: [SevereFindingAlert] = []

        init(_ alerts: SevereFindingAlerts) { self.alerts = alerts }

        func review(_ findings: [SystemFinding], at now: Date) { all += alerts.due(findings, at: now) }
    }

    private func makeNotifier() -> Reviewer {
        let setting = setting
        return Reviewer(SevereFindingAlerts(notifier: RecordingNotifier(), isEnabled: { setting.isOn }))
    }

    // MARK: Auswahl

    @Test func sustainedLoadIsSevereOnlyAfterTenMinutes() {
        let load = Self.finding(.systemLoad)
        #expect(SevereFindingAlert(load, at: Self.time(599)) == nil)
        #expect(SevereFindingAlert(load, at: Self.time(600))?.category == .sustainedLoad)
        let process = Self.finding(.processLoad, subject: .process(ProcessKey(pid: 42, startTime: 7), .program("Xcode")))
        #expect(SevereFindingAlert(process, at: Self.time(600))?.category == .sustainedLoad)
    }

    @Test func thermalStateIsSevereFromSeriousOn() {
        #expect(SevereFindingAlert(Self.finding(.thermalState, peak: 1), at: Self.time(600)) == nil)
        #expect(SevereFindingAlert(Self.finding(.thermalState, peak: 2), at: Self.time(0))?.category == .thermal)
        #expect(SevereFindingAlert(Self.finding(.thermalState, tone: .critical, peak: 3), at: Self.time(0))?.category
            == .thermal)
    }

    @Test func memoryPressureIsSevereOnlyWhenCritical() {
        #expect(SevereFindingAlert(Self.finding(.memoryPressure, peak: 1), at: Self.time(3_600)) == nil)
        #expect(SevereFindingAlert(Self.finding(.memoryPressure, tone: .critical, peak: 2), at: Self.time(0))?.category
            == .memory)
    }

    @Test func endedAndOtherFindingsAreNotSevere() {
        #expect(SevereFindingAlert(Self.finding(.systemLoad, end: 900), at: Self.time(900)) == nil)
        for kind in SystemFinding.Kind.allCases
        where ![.systemLoad, .processLoad, .thermalState, .memoryPressure].contains(kind) {
            #expect(SevereFindingAlert(Self.finding(kind, tone: .critical, peak: 3), at: Self.time(3_600)) == nil)
        }
    }

    // MARK: Texte und Ziel

    @Test func textsNameDurationAndReasonAndLeadToTheWatchbook() throws {
        let load = try #require(SevereFindingAlert(Self.finding(.systemLoad, at: 30), at: Self.time(30 + 720)))
        #expect(load.title == "Dauerlast seit 12 min")
        #expect(load.body == "CPU insgesamt länger als 2 min über 80 % ausgelastet.")
        #expect(load.destination == .watchbook(Self.time(30)))

        let thermal = try #require(SevereFindingAlert(Self.finding(.thermalState, peak: 2), at: Self.time(0)))
        #expect(thermal.title == "Thermischer Zustand ernst")
        let hot = try #require(SevereFindingAlert(Self.finding(.thermalState, tone: .critical, peak: 3), at: Self.time(0)))
        #expect(hot.title == "Thermischer Zustand kritisch")

        let memory = try #require(SevereFindingAlert(Self.finding(.memoryPressure, tone: .critical, peak: 2),
                                                     at: Self.time(0)))
        #expect(memory.title == "Kritischer Speicherdruck")
        #expect(memory.body.hasPrefix("macOS meldet kritischen Speicherdruck"))
    }

    @Test func textsNameOwnProgramsButNeverOtherAccountsOrCommandLines() throws {
        let key = ProcessKey(pid: 42, startTime: 7)
        let own = try #require(SevereFindingAlert(
            Self.finding(.processLoad, subject: .process(key, .program("node"))), at: Self.time(600)))
        #expect(own.body == "node belegt länger als 5 min mehr als 90 % eines Kerns.")

        let foreign = try #require(SevereFindingAlert(
            Self.finding(.processLoad, subject: .process(key, .otherAccounts)), at: Self.time(600)))
        #expect(foreign.body == "Ein Prozess eines anderen Kontos belegt länger als 5 min mehr als 90 % eines Kerns.")

        // Der Bezug trägt nur den Programmnamen (keine Argumente); auch ein ungewöhnlicher Name bleibt eine Zeile.
        let multiline = try #require(SevereFindingAlert(
            Self.finding(.processLoad, subject: .process(key, .program("node\n--token geheim"))), at: Self.time(600)))
        #expect(!multiline.title.contains("\n") && !multiline.body.contains("\n"))
    }

    @Test func destinationRoundTripsThroughUserInfo() {
        let destination = NotificationDestination.watchbook(Date(timeIntervalSince1970: 1_800_000_123))
        #expect(NotificationDestination(userInfo: destination.userInfo) == destination)
        #expect(NotificationDestination(userInfo: ["destination": "watchbook:"]) == nil)
        #expect(NotificationDestination(userInfo: ["destination": "watchbook:abc"]) == nil)
    }

    // MARK: Drosselung

    @Test func notifiesOncePerFindingAndOncePerCategoryAndHour() {
        let alerts = makeNotifier()
        let load = Self.finding(.systemLoad)
        alerts.review([load], at: Self.time(590))
        #expect(alerts.all.isEmpty)
        alerts.review([load], at: Self.time(600))
        alerts.review([load], at: Self.time(610))
        #expect(alerts.all.count == 1)
        #expect(alerts.all.first?.destination == .watchbook(Self.start))

        // Ein zweiter Befund derselben Art innerhalb der Stunde bleibt stumm, auch als Prozesslast.
        let process = Self.finding(.processLoad, at: 100,
                                   subject: .process(ProcessKey(pid: 42, startTime: 7), .program("node")))
        alerts.review([load, process], at: Self.time(1_200))
        #expect(alerts.all.count == 1)

        // Andere Arten sind unabhängig.
        alerts.review([load, Self.finding(.memoryPressure, tone: .critical, at: 1_200, peak: 2)],
                            at: Self.time(1_210))
        #expect(alerts.all.count == 2)

        // Nach einer Stunde darf ein neuer Befund der Art wieder melden, der schon gemeldete nicht.
        alerts.review([load], at: Self.time(600 + 3_600))
        #expect(alerts.all.count == 2)
        let next = Self.finding(.systemLoad, at: 3_000)
        alerts.review([next], at: Self.time(600 + 3_600))
        #expect(alerts.all.count == 3)
        #expect(alerts.all.last?.destination == .watchbook(Self.time(3_000)))
    }

    @Test func picksTheMostSevereFindingOfACategory() {
        let alerts = makeNotifier()
        alerts.review([Self.finding(.thermalState, at: 0, peak: 2),
                             Self.finding(.thermalState, tone: .critical, at: 60, peak: 3)], at: Self.time(120))
        #expect(alerts.all.map(\.title) == ["Thermischer Zustand kritisch"])
    }

    @Test func settingIsOnByDefault() {
        let preferences = SevereFindingAlertPreferences(store: InMemorySettingsStore())
        #expect(preferences.isEnabled)
        preferences.isEnabled = false
        #expect(!preferences.isEnabled)
    }

    @Test func disabledSettingPostsNothingAndKeepsTheHourFree() {
        setting.isOn = false
        let alerts = makeNotifier()
        let memory = Self.finding(.memoryPressure, tone: .critical, peak: 2)
        alerts.review([memory], at: Self.time(10))
        #expect(alerts.all.isEmpty)
        setting.isOn = true
        alerts.review([memory], at: Self.time(20))
        #expect(alerts.all.count == 1)
    }

    @Test func clockGoingBackwardsDoesNotSilenceForever() {
        let alerts = makeNotifier()
        alerts.review([Self.finding(.memoryPressure, tone: .critical, at: 7_200, peak: 2)], at: Self.time(7_200))
        // Uhr zurückgestellt: Die Sperre gilt nur eine Stunde ab der letzten Meldung, nicht bis die Uhr sie wieder einholt.
        alerts.review([Self.finding(.memoryPressure, tone: .critical, at: 0, peak: 2)], at: Self.time(0))
        #expect(alerts.all.count == 2)
    }
}
