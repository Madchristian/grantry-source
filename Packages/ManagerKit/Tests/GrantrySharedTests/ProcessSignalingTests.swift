import Darwin
import Synchronization
import Testing
@testable import GrantryShared

@Suite struct ProcessSignalingTests {
    private final class Calls: Sendable {
        let log = Mutex<[String]>([])
    }

    /// Token mit PID 4242 und der Generation `version`.
    private static func token(pid: pid_t = 4242, version: UInt32 = 7) -> ProcessAuditToken {
        var raw = audit_token_t()
        raw.val.5 = UInt32(bitPattern: pid)
        raw.val.7 = version
        return ProcessAuditToken(raw)
    }

    private static func process(pid: pid_t = 4242, token: ProcessAuditToken? = token()) -> RunningProcess {
        RunningProcess(pid: pid, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1, auditToken: token)
    }

    private func signaler(returning code: Int32, calls: Calls = Calls()) -> PosixProcessSignaler {
        PosixProcessSignaler(deliver: { token, signal in
            calls.log.withLock { $0.append("\(token.pid):\(signal)") }
            return code
        })
    }

    @Test func mapsSignals() {
        #expect(TerminationSignal(force: false) == .terminate && TerminationSignal.terminate.number == SIGTERM)
        #expect(TerminationSignal(force: true) == .kill && TerminationSignal.kill.number == SIGKILL)
    }

    @Test func deliveredAndAlreadyGone() throws {
        let calls = Calls()
        #expect(try signaler(returning: 0, calls: calls).send(.terminate, to: Self.process()) == .delivered)
        #expect(try signaler(returning: ESRCH).send(.kill, to: Self.process()) == .alreadyGone)
        #expect(calls.log.withLock { $0 } == ["4242:\(SIGTERM)"])
    }

    @Test func permissionAndOtherErrorsThrow() {
        #expect(throws: ProcessTerminationViolation.notPermitted(4242)) {
            try signaler(returning: EPERM).send(.terminate, to: Self.process())
        }
        #expect(throws: ProcessTerminationViolation.signalFailed(4242, errno: EINVAL)) {
            try signaler(returning: EINVAL).send(.terminate, to: Self.process())
        }
    }

    /// Das Signal geht an die Prozessgeneration (Token), nicht an die PID: Ohne Token oder mit dem Token eines anderen
    /// Prozesses wird nichts gesendet (#153, Befund 1).
    @Test func withoutMatchingTokenNothingIsSent() {
        let calls = Calls()
        #expect(throws: ProcessTerminationViolation.identityUnknown(4242)) {
            try signaler(returning: 0, calls: calls).send(.terminate, to: Self.process(token: nil))
        }
        #expect(throws: ProcessTerminationViolation.identityUnknown(4242)) {
            try signaler(returning: 0, calls: calls).send(.terminate, to: Self.process(token: Self.token(pid: 4243)))
        }
        #expect(calls.log.withLock { $0 }.isEmpty)
    }

    /// `kill(0)` träfe die Prozessgruppe, `kill(-1)` alle Prozesse, PID 1 ist launchd – nie aufrufen.
    @Test(arguments: [1, 0, -1] as [pid_t])
    func neverSignalsSpecialPIDs(_ pid: pid_t) {
        let calls = Calls()
        #expect(throws: ProcessTerminationViolation.protectedProcess(pid)) {
            try signaler(returning: 0, calls: calls).send(.kill, to: Self.process(pid: pid, token: Self.token(pid: pid)))
        }
        #expect(calls.log.withLock { $0 }.isEmpty)
    }
}
