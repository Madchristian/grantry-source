import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import GrantryShared
@testable import HelperCore

/// Task-Manager-Befehle des Helpers (TM9): Prüfung vor und nach der Admin-Bestätigung, Schutzliste, Frist, Sensoren.
@Suite struct HelperTaskActionTests {
    /// Admin-Bestätigung ohne Dialog: merkt sich die Texte, antwortet fest oder führt vorher `during` aus (etwa ein
    /// Prozesswechsel, während der Dialog offen ist).
    final class FakeAuthorizer: ActionAuthorizing {
        private let prompts = Mutex<[String]>([])
        private let result: TaskActionViolation?
        private let during: @Sendable () -> Void

        init(failing result: TaskActionViolation? = nil, during: @escaping @Sendable () -> Void = {}) {
            self.result = result
            self.during = during
        }

        var asked: [String] { prompts.withLock { $0 } }

        func authorize(_ externalForm: Data, prompt: String) throws(TaskActionViolation) {
            prompts.withLock { $0.append(prompt) }
            during()
            if let result { throw result }
        }
    }

    final class RecordingPrioritySetter: ProcessPrioritySetting {
        private let log = Mutex<[ProcessPriority]>([])
        var set: [ProcessPriority] { log.withLock { $0 } }

        func setPriority(_ priority: ProcessPriority, of process: RunningProcess) throws(ProcessPriorityFailure) {
            log.withLock { $0.append(priority) }
        }

        func niceValue(of pid: pid_t) -> Int32? { 0 }
    }

    /// Prozessliste, die sich im Test ändert (Prozesswechsel während des Dialogs).
    final class MutableInspector: ProcessInspecting {
        private let processes: Mutex<[pid_t: RunningProcess]>

        init(_ processes: [RunningProcess]) {
            self.processes = Mutex(Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) }))
        }

        func replace(_ process: RunningProcess) { processes.withLock { $0[process.pid] = process } }
        func remove(_ pid: pid_t) { _ = processes.withLock { $0.removeValue(forKey: pid) } }

        func process(_ pid: pid_t) -> RunningProcess? { processes.withLock { $0[pid] } }
        func liveness(of pid: pid_t) -> ProcessLiveness { FixedProcessInspector.liveness(of: process(pid)) }
    }

    static let token = ProcessAuditToken(pid: getpid())
    static let agent = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/agent", startTime: 1,
                                      auditToken: token)
    static let windowServer = RunningProcess(
        pid: 606, uid: 88,
        executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
        startTime: 1, auditToken: token
    )
    static let authorization = Data(count: TaskActionViolation.authorizationLength)

    private func service(
        _ inspector: any ProcessInspecting = FixedProcessInspector([HelperTaskActionTests.agent, HelperTaskActionTests.windowServer]),
        authorizer: FakeAuthorizer = FakeAuthorizer(), signaler: any ProcessSignaling = RecordingSignaler(),
        prioritySetter: any ProcessPrioritySetting = RecordingPrioritySetter(), runner: any CommandRunning = MockCommandRunner(),
        clock: TestClock = TestClock(), callerUID: uid_t? = 501
    ) -> HelperService {
        HelperService(
            runner: runner, processSignaler: signaler, callerPID: { 777 }, clock: clock,
            taskPolicy: ProcessTerminationPolicy(inspector: inspector, ownPID: 555,
                                                 protectedBundlePaths: ["/Applications/Grantry.app"],
                                                 protectedProcesses: .system),
            authorizer: authorizer, prioritySetter: prioritySetter, callerUID: { callerUID },
            userName: { $0 == 0 ? "root" : "_windowserver" }
        )
    }

    private func terminate(_ sut: HelperService, pid: Int32 = 4242, path: String = "/usr/local/sbin/agent",
                           startTime: UInt64 = 1, force: Bool = false,
                           authorization: Data = HelperTaskActionTests.authorization) async -> String? {
        await withCheckedContinuation { continuation in
            sut.terminateTaskProcess(pid: pid, executablePath: path, startTime: startTime, force: force,
                                     authorization: authorization) { continuation.resume(returning: $0) }
        }
    }

    private func setPriority(_ sut: HelperService, _ priority: Int32, pid: Int32 = 4242,
                             path: String = "/usr/local/sbin/agent") async -> String? {
        await withCheckedContinuation { continuation in
            sut.setTaskProcessPriority(pid: pid, executablePath: path, startTime: 1, priority: priority,
                                       authorization: Self.authorization) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Beenden

    @Test func asksAdminWithHelperTextThenSignals() async {
        let authorizer = FakeAuthorizer(), signaler = RecordingSignaler()
        let sut = service(authorizer: authorizer, signaler: signaler)
        #expect(await terminate(sut) == nil)
        #expect(await terminate(sut, force: true) == nil)
        #expect(signaler.sent == [.init(signal: .terminate, pid: 4242), .init(signal: .kill, pid: 4242)])
        #expect(authorizer.asked == [
            "Grantry möchte „agent“ (PID 4242, Benutzer root) beenden.",
            "Grantry möchte „agent“ (PID 4242, Benutzer root) sofort beenden (SIGKILL).",
        ])
    }

    @Test func canceledOrDeniedConfirmationSendsNothing() async {
        let signaler = RecordingSignaler()
        #expect(await terminate(service(authorizer: FakeAuthorizer(failing: .authorizationCanceled), signaler: signaler))
            == "Admin-Bestätigung abgebrochen – nichts geändert")
        #expect(await terminate(service(authorizer: FakeAuthorizer(failing: .authorizationDenied(-60005)), signaler: signaler))
            == "Admin-Bestätigung abgelehnt (-60005) – nichts geändert")
        #expect(signaler.sent.isEmpty)
    }

    /// Abgelehnt **vor** dem Dialog: Schutzliste, eigener Prozess des Aufrufers, Grantry, PID ≤ 1, Aufrufer, geänderte
    /// Identität, falsche Form der Bestätigung, unbekannter Aufrufer.
    @Test func rejectsBeforeAskingAdmin() async {
        let authorizer = FakeAuthorizer(), signaler = RecordingSignaler()
        let grantry = RunningProcess(pid: 600, uid: 0, executablePath: "/Applications/Grantry.app/Contents/MacOS/Grantry",
                                     startTime: 1, auditToken: Self.token)
        let inspector = FixedProcessInspector([Self.agent, Self.windowServer, grantry])
        let sut = service(inspector, authorizer: authorizer, signaler: signaler)
        let rejections = [
            await terminate(sut, pid: 606, path: Self.windowServer.executablePath),
            await terminate(service(inspector, authorizer: authorizer, callerUID: 0)),
            await terminate(sut, pid: 600, path: grantry.executablePath),
            await terminate(sut, pid: 1, path: "/sbin/launchd"),
            await terminate(sut, pid: 777),
            await terminate(sut, startTime: 2),
            await terminate(sut, path: "/usr/local/sbin/other"),
            await terminate(sut, authorization: Data(count: 8)),
            await terminate(service(inspector, authorizer: authorizer, callerUID: nil)),
        ]
        #expect(rejections == [
            "„WindowServer“ ist für macOS unverzichtbar – Grantry beendet den Prozess nicht und ändert seine Priorität nicht",
            "Prozess 4242 gehört dir – den beendet Grantry ohne Helper",
            "Grantry beendet sich nicht selbst: Grantry",
            "Prozess 1 ist geschützt und wird nicht beendet",
            "Prozess 777 ist geschützt und wird nicht beendet",
            "Prozess 4242 hat sich geändert – Aktion abgebrochen",
            "Prozess 4242 hat sich geändert – Aktion abgebrochen",
            "Admin-Bestätigung ungültig – Aktion abgebrochen",
            "Aufrufer nicht feststellbar – Aktion abgebrochen",
        ])
        #expect(authorizer.asked.isEmpty)
        #expect(signaler.sent.isEmpty)
    }

    /// Ohne Audit-Token (Prozessgeneration nicht lesbar) kein Dialog und kein Signal (fail-closed).
    @Test func missingAuditTokenIsRejected() async {
        let authorizer = FakeAuthorizer()
        let tokenless = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/agent", startTime: 1)
        #expect(await terminate(service(FixedProcessInspector([tokenless]), authorizer: authorizer))
            == "Identität von Prozess 4242 nicht sicher bestimmbar – Aktion abgebrochen")
        #expect(authorizer.asked.isEmpty)
    }

    @Test func endedProcessIsSuccessWithoutDialog() async {
        let authorizer = FakeAuthorizer(), signaler = RecordingSignaler()
        #expect(await terminate(service(FixedProcessInspector([]), authorizer: authorizer, signaler: signaler)) == nil)
        #expect(authorizer.asked.isEmpty && signaler.sent.isEmpty)
    }

    /// Während der Dialog offen ist, startet unter derselben PID ein anderer Prozess: kein Signal.
    @Test func processReplacedDuringDialogIsNotSignalled() async {
        let inspector = MutableInspector([Self.agent]), signaler = RecordingSignaler()
        let successor = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/agent", startTime: 9,
                                       auditToken: Self.token)
        let sut = service(inspector, authorizer: FakeAuthorizer(during: { inspector.replace(successor) }), signaler: signaler)
        #expect(await terminate(sut) == "Prozess 4242 hat sich geändert – Aktion abgebrochen")
        #expect(signaler.sent.isEmpty)
    }

    @Test func processEndedDuringDialogIsSuccess() async {
        let inspector = MutableInspector([Self.agent]), signaler = RecordingSignaler()
        let sut = service(inspector, authorizer: FakeAuthorizer(during: { inspector.remove(4242) }), signaler: signaler)
        #expect(await terminate(sut) == nil)
        #expect(signaler.sent.isEmpty)
    }

    /// Hat der Mensch länger als `taskRequestLifetime` gebraucht, handelt der Helper nicht mehr (der Client hat dann
    /// womöglich schon aufgegeben).
    @Test func lateConfirmationExpires() async {
        let clock = TestClock(), signaler = RecordingSignaler()
        let authorizer = FakeAuthorizer(during: { clock.advance(by: HelperService.taskRequestLifetime + .seconds(1)) })
        #expect(await terminate(service(authorizer: authorizer, signaler: signaler, clock: clock))
            == "Auftrag für Prozess 4242 abgelaufen – kein Signal gesendet")
        #expect(signaler.sent.isEmpty)
    }

    @Test func clientWaitsLongerThanHelperLifetime() {
        #expect(HelperService.taskRequestLifetime == .seconds(120))
    }

    /// Lange Programmnamen werden im Dialog gekürzt, Zeilenumbrüche entfernt.
    @Test func promptShortensAndFlattensName() {
        let long = RunningProcess(pid: 9, uid: 0, executablePath: "/x/" + String(repeating: "a", count: 80) + "\nb",
                                  startTime: 1)
        let prompt = AdminAuthorization.prompt("beenden", process: long, userName: "ro\not")
        #expect(prompt == "Grantry möchte „" + String(repeating: "a", count: 59) + "…“ (PID 9, Benutzer ro ot) beenden.")
    }

    // MARK: - Priorität

    @Test func setsAllowedPriorityAfterConfirmation() async {
        let setter = RecordingPrioritySetter(), authorizer = FakeAuthorizer()
        let sut = service(authorizer: authorizer, prioritySetter: setter, callerUID: 0)
        #expect(await setPriority(sut, -10) == nil)
        #expect(await setPriority(sut, 10) == nil)
        #expect(setter.set == [.high, .low])
        #expect(authorizer.asked.first == "Grantry möchte „agent“ (PID 4242, Benutzer root) auf Priorität „Hoch“ setzen.")
    }

    @Test func rejectsOtherPriorityValuesWithoutDialog() async {
        let setter = RecordingPrioritySetter(), authorizer = FakeAuthorizer()
        let sut = service(authorizer: authorizer, prioritySetter: setter)
        #expect(await setPriority(sut, -20) == "Priorität -20 ist nicht erlaubt")
        #expect(await setPriority(sut, 3) == "Priorität 3 ist nicht erlaubt")
        #expect(await setPriority(sut, 0, pid: 606, path: Self.windowServer.executablePath)
            == "„WindowServer“ ist für macOS unverzichtbar – Grantry beendet den Prozess nicht und ändert seine Priorität nicht")
        #expect(setter.set.isEmpty && authorizer.asked.isEmpty)
    }

    @Test func priorityForEndedProcessIsAnError() async {
        #expect(await setPriority(service(FixedProcessInspector([])), 5) == "Prozess 4242 läuft nicht mehr")
    }

    // MARK: - Sensoren

    private func readSensors(_ sut: HelperService) async -> (Data?, String?) {
        await withCheckedContinuation { continuation in
            sut.readSensors { continuation.resume(returning: ($0, $1)) }
        }
    }

    private static let powermetricsLine = ([PowerMetricsParser.executable] + PowerMetricsParser.arguments)
        .joined(separator: " ")

    @Test func readsSensorsWithFixedCommandLine() async throws {
        let runner = MockCommandRunner([
            Self.powermetricsLine: CommandResult(exitCode: 0, stdout: PowerMetricsSample.text + "\0", stderr: ""),
        ])
        let (data, error) = await readSensors(service(runner: runner))
        #expect(error == nil)
        let reading = try JSONDecoder().decode(SensorReading.self, from: try #require(data))
        #expect(reading.combinedMilliwatts == 2460.5)
        #expect(reading.thermalPressure == .moderate)
        #expect(runner.calls == [Self.powermetricsLine])
    }

    @Test func sensorFailureIsReported() async {
        let runner = MockCommandRunner([
            Self.powermetricsLine: CommandResult(exitCode: 1, stdout: "", stderr: "powermetrics must be invoked as the superuser"),
        ])
        let (data, error) = await readSensors(service(runner: runner))
        #expect(data == nil)
        #expect(error == "powermetrics fehlgeschlagen (Exit 1): powermetrics must be invoked as the superuser")
    }

    /// Mehr als ein Dokument zulässt, liest der Helper gar nicht erst ein (#355).
    @Test func oversizedSensorOutputIsRejected() async {
        let oversized = String(repeating: "x", count: PowerMetricsParser.maximumDocumentBytes + 1)
        let runner = MockCommandRunner([
            Self.powermetricsLine: CommandResult(exitCode: 0, stdout: oversized, stderr: ""),
        ])
        let (data, error) = await readSensors(service(runner: runner))
        #expect(data == nil)
        #expect(error == CommandError.outputTooLarge(executable: PowerMetricsParser.executable,
                                                     limit: PowerMetricsParser.maximumDocumentBytes).errorDescription)
    }

    /// Echt, ohne Dialog: Eine Ref aus 32 Null-Bytes erkennt Authorization Services nicht.
    @Test func zeroExternalFormIsDeniedWithoutDialog() {
        #expect(throws: TaskActionViolation.self) {
            _ = try AdminRightAuthorizer.reference(from: Self.authorization)
        }
    }
}

/// Eine Probe von `powermetrics -f plist` (Aufbau wie `PowerMetricsParserTests.sample`).
enum PowerMetricsSample {
    static let text = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict><key>processor</key><dict>
      <key>cpu_power</key><real>2150.5</real><key>combined_power</key><real>2460.5</real>
    </dict><key>thermal_pressure</key><string>Moderate</string></dict></plist>
    """
}
