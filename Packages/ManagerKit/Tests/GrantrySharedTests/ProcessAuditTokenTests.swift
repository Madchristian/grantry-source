import Darwin
import Foundation
import Testing
@testable import GrantryShared

/// Echte Signale nur an einen selbst gestarteten `/bin/sleep 30` (Leitplanke 5).
@Suite(.serialized) struct ProcessAuditTokenTests {
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test func readsOwnChildAndIsStable() throws {
        let child = try sleeper()
        defer { child.terminate(); child.waitUntilExit() }
        let token = try #require(ProcessAuditToken(pid: child.processIdentifier))
        #expect(token.pid == child.processIdentifier)
        #expect(ProcessAuditToken(pid: child.processIdentifier) == token)
        #expect(token.raw.val.5 == UInt32(bitPattern: child.processIdentifier))
    }

    @Test func endedChildHasNoToken() throws {
        let child = try sleeper()
        child.terminate()
        child.waitUntilExit()
        #expect(ProcessAuditToken(pid: child.processIdentifier) == nil)
    }

    @Test(arguments: [0, -1] as [pid_t])
    func invalidPIDsHaveNoToken(_ pid: pid_t) {
        #expect(ProcessAuditToken(pid: pid) == nil)
    }

    /// Der Kern des Fixes zu #153, Befund 1: `kill(pid, …)` träfe jeden Prozess, der gerade die PID hat. Ein Signal mit
    /// Token einer **anderen** Generation (hier: `pidversion` verfälscht) trifft den laufenden Prozess nicht – der Kernel
    /// meldet `ESRCH` („bereits beendet“), und das Kind läuft weiter.
    @Test func signalWithAnotherGenerationDoesNotHitTheProcess() throws {
        let child = try sleeper()
        defer { child.terminate(); child.waitUntilExit() }
        let actual = try #require(LibprocProcessInspector().process(child.processIdentifier))
        var stale = try #require(actual.auditToken).raw
        stale.val.7 &+= 1
        let other = RunningProcess(
            pid: actual.pid, uid: actual.uid, executablePath: actual.executablePath, startTime: actual.startTime,
            auditToken: ProcessAuditToken(stale)
        )
        #expect(try PosixProcessSignaler().send(.terminate, to: other) == .alreadyGone)
        usleep(50_000)
        #expect(child.isRunning)
    }

    /// Mit dem echten Token kommt das Signal an; nach dem Ende des Prozesses ist dasselbe Token `ESRCH`.
    @Test(.timeLimit(.minutes(1))) func signalWithTheProcessesTokenIsDelivered() throws {
        let child = try sleeper()
        defer { if child.isRunning { child.terminate() } }
        let process = try #require(LibprocProcessInspector().process(child.processIdentifier))
        #expect(try PosixProcessSignaler().send(.terminate, to: process) == .delivered)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
        #expect(try PosixProcessSignaler().send(.terminate, to: process) == .alreadyGone)
    }
}
