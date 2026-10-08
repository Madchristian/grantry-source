import Foundation
import Synchronization
import Testing
@testable import GrantryShared

@Suite struct RunningProcessTests {
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private static func microseconds(_ date: Date) -> UInt64 { UInt64(date.timeIntervalSince1970 * 1_000_000) }

    @Test func readsOwnChild() throws {
        let before = Self.microseconds(Date()) - 1_000_000
        let child = try sleeper()
        defer { child.terminate(); child.waitUntilExit() }
        let process = try #require(LibprocProcessInspector().process(child.processIdentifier))
        #expect(process.pid == child.processIdentifier && process.uid == getuid() && process.executablePath == "/bin/sleep")
        #expect((before...Self.microseconds(Date()) + 1_000_000).contains(process.startTime))
        #expect(process.auditToken == ProcessAuditToken(pid: child.processIdentifier))
    }

    /// Die Startzeit unterscheidet den Prozess von einem späteren mit derselben PID; sie ändert sich nicht.
    @Test func startTimeIsStable() throws {
        let child = try sleeper()
        defer { child.terminate(); child.waitUntilExit() }
        let first = try #require(LibprocProcessInspector().process(child.processIdentifier))
        #expect(LibprocProcessInspector().process(child.processIdentifier) == first)
    }

    /// Ein beendetes und geerntetes Kind gilt nicht mehr als laufend (`waitUntilExit` erntet es).
    @Test func endedChildIsGone() throws {
        let child = try sleeper()
        child.terminate()
        child.waitUntilExit()
        #expect(LibprocProcessInspector().process(child.processIdentifier) == nil)
    }

    /// Fremde root-Prozesse sind als Benutzer lesbar (`launchd`), auch ihre Startzeit – nur ihre Generation (Token)
    /// nicht; die liest allein der Helper als root.
    @Test func readsLaunchdAsUser() throws {
        let launchd = try #require(LibprocProcessInspector().process(1))
        #expect(launchd.uid == 0)
        #expect(launchd.executablePath == "/sbin/launchd")
        #expect(launchd.startTime > 0 && launchd.startTime < Self.microseconds(Date()))
        #expect((launchd.auditToken == nil) == (getuid() != 0))
    }

    /// Ein beendetes, noch nicht geerntetes Kind (Zombie) gilt als beendet, obwohl `kill(pid, 0)` es noch meldet.
    /// Gestartet per `posix_spawn`, damit nichts das Kind vor der Prüfung erntet; danach erntet der Test es selbst.
    @Test func zombieChildIsGone() throws {
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { arguments.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/usr/bin/true", nil, nil, &arguments, environ) == 0)
        defer { var status: Int32 = 0; waitpid(pid, &status, 0) }
        let deadline = Date().addingTimeInterval(5)
        while LibprocProcessInspector().process(pid) != nil, Date() < deadline { usleep(10_000) }
        #expect(LibprocProcessInspector().process(pid) == nil)
        #expect(LibprocProcessInspector().liveness(of: pid) == .absent)
        #expect(kill(pid, 0) == 0, "noch nicht geerntet")
    }

    /// Startzeit fail-closed: Negative, überlaufende oder ungültige Werte machen den Prozess unlesbar.
    @Test func startTimeIsFailClosed() {
        #expect(LibprocProcessInspector.microseconds(timeval(tv_sec: 2, tv_usec: 5)) == 2_000_005)
        #expect(LibprocProcessInspector.microseconds(timeval(tv_sec: -1, tv_usec: 0)) == nil)
        #expect(LibprocProcessInspector.microseconds(timeval(tv_sec: 1, tv_usec: -1)) == nil)
        #expect(LibprocProcessInspector.microseconds(timeval(tv_sec: 1, tv_usec: 1_000_000)) == nil)
        #expect(LibprocProcessInspector.microseconds(timeval(tv_sec: .max, tv_usec: 0)) == nil)
    }

    @Test(arguments: [0, -1] as [pid_t])
    func invalidPIDsAreNil(_ pid: pid_t) {
        #expect(LibprocProcessInspector().process(pid) == nil)
    }
    // MARK: Identität vs. Exitnachweis (#153, Codex-Runde 3)

    /// Token der Generation `version` für `pid` (Index 5: PID, Index 7: `pidversion`).
    private static func token(pid: pid_t, version: UInt32) -> ProcessAuditToken {
        var raw = audit_token_t()
        raw.val.5 = UInt32(bitPattern: pid)
        raw.val.7 = version
        return ProcessAuditToken(raw)
    }

    /// Inspektor mit fester Prozesstabelle; das Token wechselt nach der ersten Lesung die Generation – ein `exec`
    /// zwischen den beiden Lesungen (XNU ändert dabei die `pidversion`).
    private static func execDuringRead(_ lookup: LibprocProcessInspector.KernelLookup) -> LibprocProcessInspector {
        let reads = Mutex(0)
        return LibprocProcessInspector(
            kernel: { _ in lookup },
            executablePath: { _ in "/usr/local/bin/service" },
            auditToken: { pid in token(pid: pid, version: reads.withLock { reads in defer { reads += 1 }; return UInt32(reads) }) }
        )
    }

    private static let runningEntry = LibprocProcessInspector.KernelEntry(uid: 0, startTime: 7_000, isZombie: false)

    /// Ein `exec` zwischen den Token-Lesungen: Die Identität ist nicht bestätigt (`process` liefert `nil`), aber PID und
    /// Startzeit bestehen – `liveness` meldet ihn laufend, `hasEnded` ist `false`.
    @Test func execBetweenTokenReadsIsUnconfirmedButRunning() {
        let inspector = Self.execDuringRead(.found(Self.runningEntry))
        #expect(inspector.process(4242) == nil)
        #expect(inspector.liveness(of: 4242) == .running(startTime: 7_000))
        #expect(!inspector.hasEnded(4242, startedAt: 7_000))
        #expect(inspector.hasEnded(4242, startedAt: 6_000), "andere Startzeit: PID neu vergeben")
    }

    /// Exitnachweis nur aus der Prozesstabelle: fehlend oder Zombie ist beendet; eine gescheiterte Abfrage oder eine
    /// ungültige Startzeit belegt nichts.
    @Test func livenessComesFromTheProcessTableOnly() {
        let zombie = LibprocProcessInspector.KernelEntry(uid: 0, startTime: 7_000, isZombie: true)
        let invalidStart = LibprocProcessInspector.KernelEntry(uid: 0, startTime: nil, isZombie: false)
        #expect(Self.execDuringRead(.missing).liveness(of: 4242) == .absent)
        #expect(Self.execDuringRead(.found(zombie)).liveness(of: 4242) == .absent)
        #expect(Self.execDuringRead(.failed).liveness(of: 4242) == .unknown)
        #expect(Self.execDuringRead(.found(invalidStart)).liveness(of: 4242) == .unknown)
        #expect(!Self.execDuringRead(.failed).hasEnded(4242, startedAt: 7_000))
        #expect(Self.execDuringRead(.missing).hasEnded(4242, startedAt: 7_000))
    }

    /// Echte Prozesstabelle: ein eigenes Kind läuft mit seiner Startzeit, nach dem Ernten fehlt es.
    @Test func livenessOfOwnChild() throws {
        let child = try sleeper()
        let process = try #require(LibprocProcessInspector().process(child.processIdentifier))
        #expect(LibprocProcessInspector().liveness(of: child.processIdentifier) == .running(startTime: process.startTime))
        child.terminate()
        child.waitUntilExit()
        #expect(LibprocProcessInspector().liveness(of: child.processIdentifier) == .absent)
        #expect(LibprocProcessInspector().hasEnded(process.pid, startedAt: process.startTime))
    }
}
