import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Die echten Aufrufer müssen ihre synchronen Systemgrenzen verlassen, bevor sie dort warten.
/// Ein Task.detached wäre weiterhin ein Swift-Task und lässt diese Regressionstests scheitern.
@Suite struct BlockingSystemCallTests {
    private final class Probe: Sendable {
        private let observations = Mutex<[Bool]>([])
        func record() { observations.withLock { $0.append(withUnsafeCurrentTask { $0 != nil }) } }
        var callsInTask: [Bool] { observations.withLock { $0 } }
    }

    private struct Inspector: SigningInspecting {
        let probe: Probe
        func inspect(path: String) -> SigningInfo {
            probe.record()
            return SigningInfo(kind: .adHoc)
        }
    }

    private struct Locator: BundleLocating {
        let probe: Probe
        func location(ofBundleID bundleID: String) -> BundleLocation {
            probe.record()
            return .found(path: "/bin/ls")
        }
    }

    private struct Sockets: ListeningSocketEnumerating {
        let probe: Probe
        let result: Result<ListeningSocketScan, any Error>
        func listeningSockets() throws -> ListeningSocketScan {
            probe.record()
            return try result.get()
        }
    }

    private struct Provider: ListeningSocketProviding {
        let scan: ListeningSocketScan
        func listeningSockets() async throws -> ListeningSocketScan { scan }
    }

    private let socket = ListeningSocket(pid: 42, uid: 501, executablePath: "/bin/ls", transport: .tcp,
                                         localAddress: "127.0.0.1", localPort: 3000)

    /// Ein nicht abbrechbarer Systemaufruf; der Test wartet suspendierend auf seinen Beginn.
    private final class GatedSockets: ListeningSocketEnumerating {
        let started = AsyncStream<Void>.makeStream()
        let gate = Latch()
        private let count = Mutex(0)
        var calls: Int { count.withLock { $0 } }

        func listeningSockets() throws -> ListeningSocketScan {
            let first = count.withLock { $0 += 1; return $0 == 1 }
            if first {
                started.continuation.yield(())
                started.continuation.finish()
                gate.wait()
            }
            return ListeningSocketScan(sockets: [])
        }
    }

    /// Eine neue Queue-Brücke darf Cancellation nicht früh beantworten: Sonst könnte RunningSources trotz
    /// blockiertem Socket-Scan neue Arbeit einreihen. Läuft auch mit genau einem kooperativen Pool-Thread.
    @Test(arguments: [false, true]) func socketScanStaysOccupiedUntilActualEnd(cancel: Bool) async throws {
        let sockets = GatedSockets()
        defer { sockets.gate.release() }
        let coordinator = ScanCoordinator(sources: [NetworkListenerSource(provider: nil, local: sockets)],
                                          sourceTimeout: cancel ? .seconds(30) : .milliseconds(50))
        let scan = Task { try await coordinator.scan() }
        for await _ in sockets.started.stream { break }
        if cancel {
            scan.cancel()
            await #expect(throws: CancellationError.self) { try await scan.value }
        } else {
            #expect(try await scan.value.failedSources == [.networkListeners])
        }
        for _ in 0..<5 {
            let pending = try await coordinator.scan()
            #expect(pending.sourceErrors.first?.message == ScanCoordinator.stillRunningMessage)
        }
        #expect(sockets.calls == 1)
        sockets.gate.release()

        // Erst das tatsächliche Ende gibt die Quelle wieder frei.
        var next = try await coordinator.scan()
        let deadline = ContinuousClock.now + .seconds(5)
        while next.sourceErrors.first?.message == ScanCoordinator.stillRunningMessage, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            next = try await coordinator.scan()
        }
        #expect(next.sourceErrors.isEmpty)
        #expect(sockets.calls == 2)
    }

    @Test func concurrentAppResolutionsKeepSingleCacheTransaction() async {
        let signing = Probe()
        let resolver = AppResolver(inspector: Inspector(probe: signing))
        let identities = await withTaskGroup(of: AppIdentity.self) { group in
            for _ in 0..<12 { group.addTask { await resolver.resolve(path: "/bin/ls") } }
            return await group.reduce(into: [AppIdentity]()) { $0.append($1) }
        }
        #expect(identities.count == 12)
        #expect(identities.allSatisfy { $0.signing.kind == .adHoc })
        #expect(signing.callsInTask == [false])
    }

    @Test(arguments: [false, true]) func appResolutionLeavesSwiftTask(bundleID: Bool) async {
        let signing = Probe(), location = Probe()
        let resolver = AppResolver(locator: Locator(probe: location), inspector: Inspector(probe: signing))
        let identity = bundleID ? await resolver.resolve(bundleID: "test.app") : await resolver.resolve(path: "/bin/ls")
        #expect(identity.signing.kind == .adHoc)
        #expect(identity.presence == .present)
        #expect(signing.callsInTask == [false])
        #expect(location.callsInTask == (bundleID ? [false] : []))
        // Die zweite Auflösung nutzt weiterhin den Fingerabdruck-Cache.
        _ = await resolver.resolve(path: "/bin/ls")
        #expect(signing.callsInTask.count == 1)
    }

    @Test(arguments: [false, true]) func listenerCollectionLeavesSwiftTask(helper: Bool) async throws {
        let signing = Probe(), sockets = Probe()
        let scan = ListeningSocketScan(sockets: [socket])
        let source = NetworkListenerSource(
            provider: helper ? Provider(scan: scan) : nil,
            local: Sockets(probe: sockets, result: .success(scan)),
            mapper: NetworkListenerMapper(inspector: Inspector(probe: signing)), currentUID: 501
        )
        let result = try await source.collect()
        #expect(result.networkListeners.map(\.signing.kind) == [.adHoc])
        #expect(signing.callsInTask == [false])
        #expect(sockets.callsInTask == (helper ? [] : [false]))
        #expect(result.coversFullScope == helper)
    }

    @Test func processResolutionLeavesSwiftTaskAndPreservesSocketError() async {
        let sockets = Probe()
        let resolver = ListenerProcessResolver(provider: nil,
            local: Sockets(probe: sockets, result: .failure(POSIXError(.EACCES))), currentUID: 501)
        await #expect(throws: POSIXError(.EACCES)) {
            try await resolver.request(for: TestData.listener())
        }
        #expect(sockets.callsInTask == [false])
    }

    @Test func launchdSigningLeavesSwiftTask() async throws {
        try await ScratchDirectory.with { directory in
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["Label": "test.agent", "Program": "/bin/ls"], format: .xml, options: 0)
            try data.write(to: directory.appending(path: "test.plist"))
            let runner = MockCommandRunner()
            runner.stub("/bin/launchctl print-disabled gui/501",
                        CommandResult(exitCode: 0, stdout: "disabled services = {\n}\n"))
            runner.stub("/bin/launchctl print gui/501",
                        CommandResult(exitCode: 0, stdout: "gui/501 = {\n services = {\n }\n}\n"))
            let signing = Probe()
            let source = LaunchdSource(directories: [LaunchdDirectory(path: directory.path, kind: .launchAgent,
                                        domain: .user, launchctlDomain: "gui/501")],
                                       runner: runner, resolver: StubAppResolver(), inspector: Inspector(probe: signing))
            let result = try await source.collect()
            #expect(result.autostartItems.map(\.programSigning?.kind) == [.adHoc])
            #expect(signing.callsInTask == [false])
        }
    }
}
