import Darwin
import Foundation
import Synchronization
import Testing
@testable import GrantryShared

@Suite struct ProcessPriorityTests {
    @Test func offersFiveFixedLevelsNeverBelowMinusTen() {
        #expect(ProcessPriority.allCases.map(\.rawValue) == [-10, -5, 0, 5, 10])
        #expect(ProcessPriority(rawValue: -20) == nil)
        #expect(ProcessPriority(rawValue: 3) == nil)
    }

    @Test func nearestLevelForForeignNiceValues() {
        #expect(ProcessPriority(nearest: 0) == .normal)
        #expect(ProcessPriority(nearest: 3) == .belowNormal)
        #expect(ProcessPriority(nearest: 19) == .low)
        #expect(ProcessPriority(nearest: -20) == .high)
        #expect(ProcessPriority(nearest: -3) == .aboveNormal)
        #expect(ProcessPriority(nearest: 8) == .low)
        #expect(ProcessPriority(nearest: 2) == .normal)
    }

    @Test func setterMapsErrno() {
        let process = RunningProcess(pid: 4242, uid: 0, executablePath: "/x", startTime: 1)
        func setter(_ code: Int32) -> PosixPrioritySetter { PosixPrioritySetter(set: { _, _ in code }, get: { _ in (0, 0) }) }
        #expect(throws: Never.self) { try setter(0).setPriority(.low, of: process) }
        #expect(throws: ProcessPriorityFailure.gone(4242)) { try setter(ESRCH).setPriority(.low, of: process) }
        #expect(throws: ProcessPriorityFailure.notPermitted(4242)) { try setter(EPERM).setPriority(.high, of: process) }
        #expect(throws: ProcessPriorityFailure.failed(4242, errno: EINVAL)) { try setter(EINVAL).setPriority(.low, of: process) }
    }

    /// PID ≤ 1 erreicht `setpriority` nie (`who == 0` wäre der aufrufende Prozess).
    @Test func neverCallsSetpriorityForPIDZeroOrOne() {
        let calls = Mutex(0)
        let setter = PosixPrioritySetter(set: { _, _ in calls.withLock { $0 += 1 }; return 0 }, get: { _ in (0, 0) })
        for pid: pid_t in [0, 1] {
            #expect(throws: ProcessPriorityFailure.notPermitted(pid)) {
                try setter.setPriority(.low, of: RunningProcess(pid: pid, uid: 0, executablePath: "/x", startTime: 1))
            }
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(setter.niceValue(of: 0) == nil)
    }

    @Test func readsMinusOneAsValidNiceValue() {
        #expect(PosixPrioritySetter(set: { _, _ in 0 }, get: { _ in (-1, 0) }).niceValue(of: 42) == -1)
        #expect(PosixPrioritySetter(set: { _, _ in 0 }, get: { _ in (-1, ESRCH) }).niceValue(of: 42) == nil)
    }

    /// Echt und nur lesend: der eigene Prozess läuft mit nice 0 oder höher.
    @Test func readsOwnNiceValue() throws {
        #expect(try #require(PosixPrioritySetter().niceValue(of: getpid())) >= 0)
    }

    @Test func messagesAreGerman() {
        #expect(ProcessPriorityFailure.notPermitted(7).errorDescription
            == "Keine Berechtigung, die Priorität von Prozess 7 zu ändern")
        #expect(TaskActionViolation.priorityNotAllowed(-20).errorDescription == "Priorität -20 ist nicht erlaubt")
        #expect(TaskActionViolation.authorizationCanceled.errorDescription == "Admin-Bestätigung abgebrochen – nichts geändert")
    }

    @Test func authorizationMustHaveExternalFormLength() {
        #expect(TaskActionViolation.authorizationLength == 32)
        #expect(throws: TaskActionViolation.invalidAuthorization) {
            try TaskActionViolation.validateAuthorization(Data(count: 31))
        }
        #expect(throws: Never.self) { try TaskActionViolation.validateAuthorization(Data(count: 32)) }
    }
}
