import Foundation
import Testing
import GrantryShared
import TestSupport
@testable import ManagerKit

/// Echte Signale nur an einen selbst gestarteten `/bin/sleep 30` (Leitplanke 5).
@Suite(.serialized) struct OwnProcessSignalerTests {
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    /// Das Kind laut libproc; einzelne Angaben lassen sich verfälschen.
    private func target(
        _ child: Process, path: String = "/bin/sleep", uid: UInt32 = getuid(), startTimeOffset: UInt64 = 0
    ) throws -> RunningProcess {
        let actual = try #require(LibprocProcessInspector().process(child.processIdentifier))
        return RunningProcess(pid: actual.pid, uid: uid, executablePath: path, startTime: actual.startTime + startTimeOffset)
    }

    @Test(.timeLimit(.minutes(1))) func sigtermEndsOwnChild() throws {
        let child = try sleeper()
        defer { if child.isRunning { child.terminate() } }
        let listening = ListeningRequirement(checker: FixedListeningPIDs([child.processIdentifier]))
        try OwnProcessSignaler(policy: .app(listening: listening)).signal(target(child), .terminate)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
    }

    /// Auch die App beendet nur lauschende Prozesse (gemeinsame `ProcessTerminationPolicy`): `/bin/sleep` lauscht nicht.
    @Test func nonListeningChildIsNotSignalled() throws {
        let child = try sleeper()
        defer { child.terminate(); child.waitUntilExit() }
        #expect(throws: ProcessTerminationViolation.notListening("sleep")) {
            try OwnProcessSignaler().signal(target(child), .terminate)
        }
        #expect(child.isRunning)
    }

    @Test func changedPathAbortsWithoutSignal() throws {
        let child = try sleeper()
        defer { child.terminate(); child.waitUntilExit() }
        #expect(throws: ProcessTerminationViolation.processChanged(child.processIdentifier)) {
            try OwnProcessSignaler().signal(target(child, path: "/bin/cat"), .terminate)
        }
        #expect(child.isRunning)
    }

    /// Prozesse anderer Benutzer beendet nur der Helper.
    @Test func otherUserAbortsWithoutSignal() throws {
        let child = try sleeper()
        defer { child.terminate(); child.waitUntilExit() }
        #expect(throws: ProcessTerminationViolation.notPermitted(child.processIdentifier)) {
            try OwnProcessSignaler().signal(target(child, uid: getuid() + 1), .terminate)
        }
        #expect(child.isRunning)
    }

    /// PID-Wiederverwendung: Gleiche PID, gleicher Pfad, gleicher Benutzer, aber eine andere Startzeit – kein Signal.
    @Test func changedStartTimeAbortsWithoutSignal() throws {
        let child = try sleeper()
        defer { child.terminate(); child.waitUntilExit() }
        #expect(throws: ProcessTerminationViolation.processChanged(child.processIdentifier)) {
            try OwnProcessSignaler().signal(target(child, startTimeOffset: 1), .kill)
        }
        #expect(child.isRunning)
    }

    /// Bereits beendet (`ESRCH`-Fall): Erfolg ohne Signal.
    @Test func endedChildIsSuccess() throws {
        let child = try sleeper()
        let process = try target(child)
        child.terminate()
        child.waitUntilExit()
        try OwnProcessSignaler().signal(process, .kill)
    }
}
