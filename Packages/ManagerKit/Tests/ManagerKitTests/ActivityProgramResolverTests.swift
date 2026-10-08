import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@Suite(.timeLimit(.minutes(1))) struct ActivityProgramResolverTests {
    private let developer = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)
    private let appPath = "/Applications/A.app/Contents/MacOS/A"
    private static let original = FileFingerprint(modified: Date(timeIntervalSince1970: 1), fileNumber: 1)
    private static let updated = FileFingerprint(modified: Date(timeIntervalSince1970: 2), fileNumber: 1)

    /// Die erste Messung zeigt das Programm sofort, aber ohne Signatur (`pendingSignatures`); die Prüfung läuft auf
    /// eigener Queue, die nächste Messung bringt die Signatur.
    @Test func deliversProgramAtOnceAndSignatureLater() async {
        let lookups = Mutex<[Int32]>([])
        let inspector = RecordingSigningInspector(result: developer)
        let resolver = ActivityProgramResolver(
            executablePath: { pid in
                lookups.withLock { $0.append(pid) }
                return pid == 42 ? "/Applications/A.app/Contents/MacOS/A" : nil
            },
            inspector: inspector
        )
        let app = ProcessKey(pid: 42, startTime: 1)
        let gone = ProcessKey(pid: 43, startTime: 1)

        let first = resolver.programs(for: [app, gone])
        #expect(first.programs == [app: NetworkProgram(executablePath: appPath, signing: .unknown)])
        #expect(first.pendingSignatures == [app])

        await resolver.waitForInspections()
        let second = resolver.programs(for: [app, gone])
        #expect(second.programs == [app: NetworkProgram(executablePath: appPath, signing: developer)])
        #expect(second.pendingSignatures.isEmpty)
        #expect(lookups.withLock { $0 } == [42, 43, 42, 43], "Pfad je Messung neu gelesen (exec)")
        #expect(inspector.paths == [appPath])
    }

    /// `kernel_task` (PID 0) hat keinen Pfad; Einträge nicht mehr gemeldeter Prozesse werden neu gefragt, wenn sie
    /// wiederkommen.
    @Test func skipsKernelAndForgetsVanishedProcesses() {
        let lookups = Mutex<[Int32]>([])
        let resolver = ActivityProgramResolver(
            executablePath: { pid in
                lookups.withLock { $0.append(pid) }
                return "/usr/bin/curl"
            },
            inspector: RecordingSigningInspector(result: SigningInfo(kind: .apple))
        )
        let kernel = ProcessKey(pid: 0, startTime: 0)
        let curl = ProcessKey(pid: 7, startTime: 1)
        #expect(resolver.programs(for: [kernel, curl]).programs.keys.sorted() == [curl])
        _ = resolver.programs(for: [kernel])
        _ = resolver.programs(for: [curl])
        #expect(lookups.withLock { $0 } == [7, 7])
    }

    /// Ist der letzte Prozess eines Pfads weg, entfällt auch dessen Signatur: Ein neuer Prozess am selben Pfad (etwa nach
    /// einem Update) wird wieder über den Inspector (`CachingSigningInspector` mit Fingerabdruck) geprüft.
    @Test func forgetsSignaturesOfVanishedPaths() async {
        let inspector = RecordingSigningInspector(result: developer)
        let resolver = ActivityProgramResolver(executablePath: { [appPath] _ in appPath },
                                               fingerprint: { _ in Self.original }, inspector: inspector)
        let old = ProcessKey(pid: 42, startTime: 1)
        let restarted = ProcessKey(pid: 44, startTime: 2)

        _ = resolver.programs(for: [old])
        await resolver.waitForInspections()
        #expect(resolver.programs(for: [old]).pendingSignatures.isEmpty)
        _ = resolver.programs(for: [])

        #expect(resolver.programs(for: [restarted]).pendingSignatures == [restarted])
        await resolver.waitForInspections()
        #expect(inspector.paths == [appPath, appPath])
    }

    /// Update am selben Pfad, während der alte Prozess noch gemeldet wird (ausgegraut oder parallele Instanz): Der neue
    /// Prozess bekommt die Signatur nur bei gleichem Fingerabdruck übernommen, sonst wird neu geprüft. Der alte Prozess
    /// behält seine Signatur.
    @Test func reinspectsNewProcessWhenFingerprintChanged() async {
        let fingerprint = Mutex(Self.original)
        let inspector = CallbackSigningInspector(result: developer)
        let resolver = ActivityProgramResolver(executablePath: { [appPath] _ in appPath },
                                               fingerprint: { _ in fingerprint.withLock { $0 } }, inspector: inspector)
        let old = ProcessKey(pid: 42, startTime: 1)
        let new = ProcessKey(pid: 44, startTime: 2)
        _ = resolver.programs(for: [old])
        await resolver.waitForInspections()

        let apple = SigningInfo(kind: .apple)
        fingerprint.withLock { $0 = Self.updated }
        inspector.answer(with: apple)
        #expect(resolver.programs(for: [old, new]).pendingSignatures == [new])
        await resolver.waitForInspections()

        let resolved = resolver.programs(for: [old, new])
        #expect(resolved.pendingSignatures.isEmpty)
        #expect(resolved.programs[old]?.signing == developer)
        #expect(resolved.programs[new]?.signing == apple)
        #expect(inspector.paths == [appPath, appPath])
    }

    /// Ändert sich die Datei zwischen Auftauchen und Prüfung, passt der Fingerabdruck nicht: Der Prozess bekommt
    /// `.unknown` statt endlos zu warten, und es wird nicht bei jeder Messung erneut geprüft.
    @Test func marksWaitingProcessUnknownWhenFingerprintChangedDuringInspection() async {
        let calls = Mutex(0)
        let inspector = RecordingSigningInspector(result: developer)
        let resolver = ActivityProgramResolver(
            executablePath: { [appPath] _ in appPath },
            fingerprint: { _ in
                calls.withLock { count in
                    defer { count += 1 }
                    return count == 0 ? Self.original : Self.updated
                }
            },
            inspector: inspector
        )
        let key = ProcessKey(pid: 42, startTime: 1)
        #expect(resolver.programs(for: [key]).pendingSignatures == [key])
        await resolver.waitForInspections()

        let resolved = resolver.programs(for: [key])
        #expect(resolved.pendingSignatures.isEmpty)
        #expect(resolved.programs[key]?.signing == .unknown)
        await resolver.waitForInspections()
        _ = resolver.programs(for: [key])
        #expect(inspector.paths == [appPath])
    }

    /// Gleicher Fingerabdruck: Ein weiterer Prozess am selben Pfad übernimmt die Signatur sofort, ohne neue Prüfung.
    @Test func reusesSignatureWhenFingerprintUnchanged() async {
        let inspector = RecordingSigningInspector(result: developer)
        let resolver = ActivityProgramResolver(executablePath: { [appPath] _ in appPath },
                                               fingerprint: { _ in Self.original }, inspector: inspector)
        let old = ProcessKey(pid: 42, startTime: 1)
        let new = ProcessKey(pid: 44, startTime: 2)
        _ = resolver.programs(for: [old])
        await resolver.waitForInspections()

        let resolved = resolver.programs(for: [old, new])
        #expect(resolved.pendingSignatures.isEmpty)
        #expect(resolved.programs[new]?.signing == developer)
        #expect(inspector.paths == [appPath])
    }

    /// `exec` wechselt das Programm bei gleicher PID und Startzeit: Der Pfad wird je Messung neu gelesen, bei einem
    /// Wechsel gelten neue Zuordnung und neuer Fingerabdruck, die Signatur wird neu geprüft (bis dahin ausstehend). Ein
    /// beendeter Prozess (Pfad nicht mehr lesbar, ausgegraut) behält sein Programm.
    @Test func reresolvesProgramAfterExec() async {
        let toolPath = "/usr/local/bin/tool"
        let path = Mutex<String?>(appPath)
        let inspector = CallbackSigningInspector(result: developer)
        let resolver = ActivityProgramResolver(executablePath: { _ in path.withLock { $0 } },
                                               fingerprint: { $0 == toolPath ? Self.updated : Self.original },
                                               inspector: inspector)
        let key = ProcessKey(pid: 42, startTime: 1)
        _ = resolver.programs(for: [key])
        await resolver.waitForInspections()

        let apple = SigningInfo(kind: .apple)
        inspector.answer(with: apple)
        path.withLock { $0 = toolPath }
        let execed = resolver.programs(for: [key])
        #expect(execed.programs[key] == NetworkProgram(executablePath: toolPath, signing: .unknown))
        #expect(execed.pendingSignatures == [key])
        await resolver.waitForInspections()
        #expect(resolver.programs(for: [key]).programs[key] == NetworkProgram(executablePath: toolPath, signing: apple))

        path.withLock { $0 = nil }
        #expect(resolver.programs(for: [key]).programs[key]?.executablePath == toolPath)
        path.withLock { $0 = appPath }
        #expect(resolver.programs(for: [key], ended: [key]).programs[key]?.executablePath == toolPath)
        #expect(inspector.paths == [appPath, toolPath])
    }

    /// Wechselt das Programm, während die Prüfung des alten Pfads läuft, gilt deren Ergebnis nicht für den neuen Pfad:
    /// Der neue wird eigens geprüft.
    @Test func inspectionOfPreviousPathDoesNotApplyAfterExec() async {
        let toolPath = "/usr/local/bin/tool"
        let path = Mutex<String?>(appPath)
        let release = DispatchSemaphore(value: 0)
        let inspector = CallbackSigningInspector(result: developer) { [appPath] inspected in
            if inspected == appPath { release.wait() }
        }
        let resolver = ActivityProgramResolver(executablePath: { _ in path.withLock { $0 } },
                                               fingerprint: { _ in Self.original }, inspector: inspector)
        let key = ProcessKey(pid: 42, startTime: 1)
        _ = resolver.programs(for: [key])
        while inspector.paths.isEmpty { await Task.yield() }

        path.withLock { $0 = toolPath }
        #expect(resolver.programs(for: [key]).pendingSignatures == [key])
        let apple = SigningInfo(kind: .apple)
        inspector.answer(with: apple)
        release.signal()
        await resolver.waitForInspections()

        #expect(resolver.programs(for: [key]).programs[key] == NetworkProgram(executablePath: toolPath, signing: apple))
        #expect(inspector.paths == [appPath, toolPath])
    }

    /// Eine Zeitüberschreitung wird je Pfad `inspectionRetryDelay` lang gemerkt: In dieser Zeit wird der Pfad nicht
    /// erneut eingereiht (der geteilte `BlockingCallGuard.signing` würde sonst alle 2 s belastet), seine Prozesse
    /// tragen `.unknown` und warten nicht. Danach wird erneut geprüft.
    @Test func timedOutPathIsNotRequeuedUntilRetryDelayPassed() async {
        let now = Mutex(ContinuousClock.now)
        let inspector = TimingOutSigningInspector()
        let resolver = ActivityProgramResolver(executablePath: { [appPath] _ in appPath },
                                               fingerprint: { _ in Self.original }, inspector: inspector,
                                               now: { now.withLock { $0 } })
        let key = ProcessKey(pid: 42, startTime: 1)
        #expect(resolver.programs(for: [key]).pendingSignatures == [key])
        await resolver.waitForInspections()

        for _ in 0..<3 {
            now.withLock { $0 += .seconds(2) }
            let resolved = resolver.programs(for: [key])
            #expect(resolved.pendingSignatures.isEmpty)
            #expect(resolved.programs[key]?.signing == .unknown)
            await resolver.waitForInspections()
        }
        #expect(inspector.count == 1)

        now.withLock { $0 += ActivityProgramResolver.inspectionRetryDelay }
        #expect(resolver.programs(for: [key]).pendingSignatures == [key])
        await resolver.waitForInspections()
        #expect(inspector.count == 2)
    }

    /// Messungen während einer hängenden Prüfung reihen ihren Pfad nicht erneut ein: Nach der Zeitüberschreitung folgt
    /// bis zum Ablauf der Sperre kein zweiter Prüfaufruf – der Pfad belegt höchstens einen Platz im
    /// `BlockingCallGuard.signing`.
    @Test func measurementsDuringHangingInspectionDoNotRequeuePath() async {
        let now = Mutex(ContinuousClock.now)
        // Nur die erste Prüfung hängt – eine doppelte soll den Test scheitern lassen, nicht aufhängen.
        let release = DispatchSemaphore(value: 0)
        let hangs = Mutex(true)
        let inspector = TimingOutSigningInspector {
            if hangs.withLock({ hanging in defer { hanging = false }; return hanging }) { release.wait() }
        }
        let resolver = ActivityProgramResolver(executablePath: { [appPath] _ in appPath },
                                               fingerprint: { _ in Self.original }, inspector: inspector,
                                               now: { now.withLock { $0 } })
        let key = ProcessKey(pid: 42, startTime: 1)
        _ = resolver.programs(for: [key])
        while inspector.count == 0 { await Task.yield() }
        for _ in 0..<3 {
            now.withLock { $0 += .seconds(2) }
            #expect(resolver.programs(for: [key]).pendingSignatures == [key])
        }
        release.signal()
        await resolver.waitForInspections()

        now.withLock { $0 += .seconds(2) }
        #expect(resolver.programs(for: [key]).pendingSignatures.isEmpty)
        await resolver.waitForInspections()
        #expect(inspector.count == 1)
    }

    /// Abgebrochene Ansicht: Noch nicht begonnene Prüfungen entfallen, eine laufende endet regulär.
    @Test func cancellationSkipsQueuedInspections() async {
        let resolverBox = Mutex<ActivityProgramResolver?>(nil)
        let inspector = CallbackSigningInspector(result: developer) { _ in
            resolverBox.withLock { $0 }?.cancelPendingInspections()
        }
        let resolver = ActivityProgramResolver(executablePath: { "/opt/tool\($0)" }, inspector: inspector)
        resolverBox.withLock { $0 = resolver }

        _ = resolver.programs(for: (1...3).map { ProcessKey(pid: $0, startTime: 1) })
        await resolver.waitForInspections()

        #expect(inspector.paths == ["/opt/tool1"])
        #expect(resolver.programs(for: [ProcessKey(pid: 1, startTime: 1)]).pendingSignatures.isEmpty)
    }

    @Test func pipelineCombinesTrackerAndPrograms() {
        let pipeline = ActivityPipeline(
            tracker: TrafficTracker(),
            programs: ActivityProgramResolver(executablePath: { _ in "/usr/bin/curl" },
                                              inspector: RecordingSigningInspector(result: SigningInfo(kind: .apple)))
        )
        let sample = NettopSample(processes: [ProcessTraffic(pid: 7, shortName: "curl", bytesIn: 1, bytesOut: 2, connections: [
            ConnectionTraffic(transport: .tcp, ipVersion: .v4, local: ConnectionEndpoint(address: "192.0.2.1", port: 50000),
                              remote: ConnectionEndpoint(address: "192.0.2.10", port: 443), state: "Established",
                              bytesIn: 1, bytesOut: 2),
        ], startTime: 5)])
        let frame = pipeline.frame(for: TimedNettopSample(sample: sample, capturedAt: .now))
        let key = ProcessKey(pid: 7, startTime: 5)
        #expect(frame.report.processes.map(\.key) == [key])
        #expect(frame.programs[key]?.executablePath == "/usr/bin/curl")
        #expect(frame.pendingSignatures == [key])
        #expect(frame.remoteAddresses == ["192.0.2.10"])
        #expect(frame.activeRemoteAddresses == ["192.0.2.10"])
    }

    /// Ausgegraute Verbindungen behalten ihren Hostnamen (`remoteAddresses`), werden aber nicht mehr nachgeschlagen
    /// (`activeRemoteAddresses`).
    @Test func frameSeparatesActiveFromShownRemoteAddresses() {
        let frame = TestData.activityFrame([TestData.processActivity(7, connections: [
            TestData.connectionActivity(remote: "192.0.2.10"),
            TestData.connectionActivity(remote: "192.0.2.20", isGone: true),
        ])])
        #expect(frame.remoteAddresses == ["192.0.2.10", "192.0.2.20"])
        #expect(frame.activeRemoteAddresses == ["192.0.2.10"])
    }
}

/// Liefert `result` (umschaltbar über `answer(with:)`), zeichnet die Pfade auf und ruft vor jeder Antwort `onInspect`.
private final class CallbackSigningInspector: SigningInspecting {
    private let result: Mutex<SigningInfo>
    private let onInspect: @Sendable (String) -> Void
    private let recorded = Mutex<[String]>([])

    init(result: SigningInfo, onInspect: @escaping @Sendable (String) -> Void = { _ in }) {
        self.result = Mutex(result)
        self.onInspect = onInspect
    }

    var paths: [String] { recorded.withLock { $0 } }

    func answer(with signing: SigningInfo) { result.withLock { $0 = signing } }

    func inspect(path: String) -> SigningInfo {
        recorded.withLock { $0.append(path) }
        onInspect(path)
        return result.withLock { $0 }
    }
}

/// Jede Prüfung endet – nach `hang` (auf der Signatur-Queue) – mit einer Zeitüberschreitung; zählt die Aufrufe.
private final class TimingOutSigningInspector: SigningInspecting {
    private let calls = Mutex(0)
    private let hang: @Sendable () -> Void

    init(hang: @escaping @Sendable () -> Void = {}) { self.hang = hang }

    var count: Int { calls.withLock { $0 } }

    func inspect(path: String) -> SigningInfo { inspection(ofPath: path).info }

    func inspection(ofPath path: String) -> SigningInspection {
        calls.withLock { $0 += 1 }
        hang()
        return .timedOut
    }
}
