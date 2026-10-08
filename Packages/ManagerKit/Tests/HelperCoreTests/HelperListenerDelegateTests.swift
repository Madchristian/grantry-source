import Testing
import Foundation
import TestSupport
import GrantryShared
@testable import HelperCore

@Suite struct HelperListenerDelegateTests {
    /// Verbindet sich über einen anonymen Listener mit `delegate` und fragt die Protokollversion ab.
    private func protocolVersion(via delegate: HelperListenerDelegate) async throws -> Int {
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = HelperXPC.makeInterface()
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! GrantryHelperXPC
            proxy.protocolVersion { continuation.resume(returning: $0) }
        }
    }

    @Test(.enabled(if: CurrentUser.isAdministrator, "Standard-Prädikat verlangt die Gruppe admin"))
    func exportsServiceOverXPCWithDefaultPredicate() async throws {
        let delegate = HelperListenerDelegate(service: HelperService(runner: MockCommandRunner()))
        #expect(try await protocolVersion(via: delegate) == HelperXPC.protocolVersion)
    }

    @Test func acceptsAuthorizedUser() async throws {
        let delegate = HelperListenerDelegate(service: HelperService(runner: MockCommandRunner()), isAuthorized: { _ in true })
        #expect(try await protocolVersion(via: delegate) == HelperXPC.protocolVersion)
    }

    @Test func rejectsUnauthorizedUser() async throws {
        let delegate = HelperListenerDelegate(service: HelperService(runner: MockCommandRunner()), isAuthorized: { _ in false })
        await #expect(throws: (any Error).self) { try await protocolVersion(via: delegate) }
    }

    @Test func passesConnectionEUIDToPredicate() async throws {
        let seen = UIDRecorder()
        let delegate = HelperListenerDelegate(service: HelperService(runner: MockCommandRunner()), isAuthorized: { uid in
            seen.set(uid)
            return true
        })
        _ = try await protocolVersion(via: delegate)
        #expect(seen.value == geteuid())
    }
}

/// Threadsicherer Speicher für die vom Prädikat gesehene UID.
private final class UIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: uid_t?
    func set(_ uid: uid_t) { lock.withLock { stored = uid } }
    var value: uid_t? { lock.withLock { stored } }
}
