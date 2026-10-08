import Foundation
import ServiceManagement
import Synchronization
import Testing
@testable import ManagerKit

@Suite struct LaunchAtLoginTests {
    /// Protokolliert Aufrufe, ohne `SMAppService` anzufassen.
    private final class FakeRegistration: AppServiceRegistration {
        private struct State {
            var status: SMAppService.Status
            var statusAfterRegister: SMAppService.Status
            var calls: [String] = []
        }

        private let state: Mutex<State>
        private let registerError: (any Error & Sendable)?

        init(
            status: SMAppService.Status,
            statusAfterRegister: SMAppService.Status = .enabled,
            registerError: (any Error & Sendable)? = nil
        ) {
            state = Mutex(State(status: status, statusAfterRegister: statusAfterRegister))
            self.registerError = registerError
        }

        var status: SMAppService.Status { state.withLock { $0.status } }
        var calls: [String] { state.withLock { $0.calls } }

        func register() throws {
            state.withLock { $0.calls.append("register") }
            if let registerError { throw registerError }
            state.withLock { $0.status = $0.statusAfterRegister }
        }

        func unregister() async throws {
            state.withLock { state in
                state.calls.append("unregister")
                state.status = .notRegistered
            }
        }
    }

    private struct Denied: Error {}

    @Test(arguments: [
        (SMAppService.Status.enabled, LoginItemStatus.enabled),
        (.notRegistered, .disabled),
        (.notFound, .disabled),
        (.requiresApproval, .requiresApproval),
    ])
    func mapsServiceStatus(service: SMAppService.Status, status: LoginItemStatus) {
        #expect(LaunchAtLogin(service: FakeRegistration(status: service)).status == status)
    }

    @Test func enablingRegisters() async throws {
        let service = FakeRegistration(status: .notRegistered)
        #expect(try await LaunchAtLogin(service: service).setEnabled(true) == .enabled)
        #expect(service.calls == ["register"])
    }

    @Test func enablingCanRequireApproval() async throws {
        let service = FakeRegistration(status: .notFound, statusAfterRegister: .requiresApproval)
        #expect(try await LaunchAtLogin(service: service).setEnabled(true) == .requiresApproval)
    }

    @Test func disablingUnregistersEvenWhileAwaitingApproval() async throws {
        let service = FakeRegistration(status: .requiresApproval)
        #expect(try await LaunchAtLogin(service: service).setEnabled(false) == .disabled)
        #expect(service.calls == ["unregister"])
    }

    @Test func leavesTheServiceAloneWhenAlreadyInTheRequestedState() async throws {
        let enabled = FakeRegistration(status: .enabled)
        #expect(try await LaunchAtLogin(service: enabled).setEnabled(true) == .enabled)
        let disabled = FakeRegistration(status: .notRegistered)
        #expect(try await LaunchAtLogin(service: disabled).setEnabled(false) == .disabled)
        #expect(enabled.calls.isEmpty && disabled.calls.isEmpty)
    }

    @Test func registrationErrorsPropagate() async {
        let service = FakeRegistration(status: .notRegistered, registerError: Denied())
        await #expect(throws: Denied.self) { try await LaunchAtLogin(service: service).setEnabled(true) }
    }
}
