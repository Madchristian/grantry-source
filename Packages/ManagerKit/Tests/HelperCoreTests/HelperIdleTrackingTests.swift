import Testing
import Foundation
import Synchronization
import TestSupport
@testable import GrantryShared
@testable import HelperCore

/// Runner, der jeden Aufruf bis zur Freigabe durch `gate` anhält und dann erfolgreich endet; `launchctl print`
/// meldet einen aus `loadedPlistPath` geladenen Dienst, damit launchctl-Operationen bis zum Befehl kommen.
final class GatedRunner: CommandRunning {
    let gate = Gate()
    private let loadedPlistPath: String?

    init(loadedPlistPath: String? = nil) {
        self.loadedPlistPath = loadedPlistPath
    }

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        try await gate.wait()
        if arguments.first == "print", let loadedPlistPath {
            return CommandResult(exitCode: 0, stdout: "\tpath = \(loadedPlistPath)\n")
        }
        return CommandResult(exitCode: 0, stdout: "")
    }
}

@Suite(.timeLimit(.minutes(1))) struct HelperIdleTrackingTests {
    @Test func runningDumpBTMCountsAsActivity() async {
        let probe = IdleProbe()
        let monitor = probe.makeMonitor()
        let runner = GatedRunner()
        let sut = HelperService(runner: runner, idleMonitor: monitor)
        sut.dumpBTM { _, _ in }
        #expect(monitor.activeCount == 1)
        runner.gate.open()
        await probe.expire(at: .seconds(300))
        #expect(await probe.idleTime() == .seconds(300))
        #expect(monitor.activeCount == 0)
    }

    @Test func queuedOperationsCountAsActivityUntilFinished() async throws {
        try await ScratchDirectory.with { dir in
            let daemons = dir.appending(path: "LaunchDaemons")
            try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
            let plist = try LaunchdPlistFixture.write(label: "com.example.daemon", in: daemons)
            let probe = IdleProbe()
            let monitor = probe.makeMonitor()
            let runner = GatedRunner(loadedPlistPath: plist.resolvingSymlinksInPath().path)
            let sut = HelperService(
                runner: runner,
                backups: PlistBackupStore(root: dir.appending(path: "Backups"), managedDirectories: [daemons.path]),
                launchDaemonsDirectory: daemons.path,
                additionalDaemonDirectories: [],
                idleMonitor: monitor
            )
            sut.bootout(plistPath: plist.path) { _ in }
            sut.setEnabled(plistPath: plist.path, enabled: false) { _ in }
            #expect(monitor.activeCount == 2)
            // Je Operation: Ladezustandsprüfung + Befehl.
            for _ in 0..<4 { runner.gate.open() }
            await probe.expire(at: .seconds(300))
            #expect(await probe.idleTime() == .seconds(300))
            #expect(monitor.activeCount == 0)
        }
    }

    @Test func openConnectionCountsAsActivityUntilInvalidated() async throws {
        let probe = IdleProbe()
        let monitor = probe.makeMonitor()
        let delegate = HelperListenerDelegate(
            service: HelperService(runner: MockCommandRunner()),
            isAuthorized: { _ in true },
            idleMonitor: monitor
        )
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = HelperXPC.makeInterface()
        connection.resume()
        let version: Int = try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! GrantryHelperXPC
            proxy.protocolVersion { continuation.resume(returning: $0) }
        }
        #expect(version == HelperXPC.protocolVersion)
        #expect(monitor.activeCount == 1)

        connection.invalidate()
        await probe.expire(at: .seconds(300))
        #expect(await probe.idleTime() == .seconds(300))
        #expect(monitor.activeCount == 0)
    }
}
