import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Zeitgrenze für Aufrufe, die blockieren können (Signaturprüfung an einer FIFO): Der Aufrufer wartet höchstens die
/// Frist, hängende Aufrufe bleiben begrenzt.
@Suite struct BlockingCallGuardTests {
    /// Gleichzeitige Aufrufe innerhalb der Frist zählen nicht als hängend.
    @Test func concurrentCallsWithinTheLimitAreNotRefused() async {
        let callGuard = BlockingCallGuard(maximumHanging: 1)
        let results = await withTaskGroup(of: Int?.self) { group in
            for index in 0..<6 {
                group.addTask { callGuard.run(timeout: .seconds(5)) { Thread.sleep(forTimeInterval: 0.05); return index } }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.compactMap(\.self).sorted() == Array(0..<6))
        #expect(callGuard.hangingCount == 0)
    }

    @Test func returnsTheResultWithinTheLimit() {
        let callGuard = BlockingCallGuard(maximumHanging: 2)
        #expect(callGuard.run(timeout: .seconds(5)) { 42 } == 42)
        #expect(callGuard.hangingCount == 0)
    }

    /// Nach Ablauf der Frist kehrt der Aufrufer mit `nil` zurück; der hängende Aufruf zählt, bis er endet.
    @Test func timesOutAndCountsTheHangingCall() async throws {
        let callGuard = BlockingCallGuard(maximumHanging: 2)
        let latch = Latch()
        let start = ContinuousClock.now
        #expect(callGuard.run(timeout: .milliseconds(50)) { latch.wait(); return 1 } == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(callGuard.hangingCount == 1)
        latch.release()
        try await waitUntil { callGuard.hangingCount == 0 }
    }

    /// Hängen bereits `maximumHanging` Aufrufe, kehrt jeder weitere sofort mit `nil` zurück, ohne zu laufen.
    @Test func refusesFurtherCallsWhileTheLimitIsReached() async throws {
        let callGuard = BlockingCallGuard(maximumHanging: 2)
        let latch = Latch()
        for _ in 0..<2 { #expect(callGuard.run(timeout: .milliseconds(20)) { latch.wait() } == nil) }
        let ran = Mutex(false)
        let start = ContinuousClock.now
        #expect(callGuard.run(timeout: .seconds(5)) { ran.withLock { $0 = true } } == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(!ran.withLock { $0 })
        latch.release(2)
        try await waitUntil { callGuard.hangingCount == 0 }
        #expect(callGuard.run(timeout: .seconds(5)) { 7 } == 7)
    }

    /// Ist die Grenze erreicht, melden Signaturprüfung und Tiefenprüfung „nicht prüfbar“, statt zu warten.
    @Test func saturatedGuardMakesSigningUnknown() async throws {
        let callGuard = BlockingCallGuard(maximumHanging: 1)
        let latch = Latch()
        #expect(callGuard.run(timeout: .milliseconds(20)) { latch.wait() } == nil)
        #expect(SecuritySigningInspector(timeout: .seconds(5), callGuard: callGuard).inspect(path: "/bin/ls") == .unknown)
        #expect(SecuritySigningInspector(timeout: .seconds(5), callGuard: callGuard).inspection(ofPath: "/bin/ls") == .timedOut)
        #expect(SecuritySignatureValidator(timeout: .seconds(5), callGuard: callGuard).validate(path: "/bin/ls") == .unverifiable)
        #expect(SecuritySignatureValidator(timeout: .seconds(5), callGuard: callGuard).validation(ofPath: "/bin/ls") == .timedOut)
        latch.release()
        try await waitUntil { callGuard.hangingCount == 0 }
        #expect(SecuritySigningInspector(timeout: .seconds(5), callGuard: callGuard).inspect(path: "/bin/ls").kind == .apple)
        #expect(SecuritySigningInspector(timeout: .seconds(5), callGuard: callGuard).inspection(ofPath: "/bin/ls").info.kind == .apple)
        #expect(SecuritySignatureValidator(timeout: .seconds(30), callGuard: callGuard).validate(path: "/bin/ls") == .valid)
    }

    @Test func standardLimitsAreBounded() {
        #expect(SecuritySigningInspector.defaultTimeout == .seconds(10))
        #expect(BlockingCallGuard.signing.maximumHanging <= 4)
        #expect(BlockingCallGuard.deepValidation.maximumHanging <= 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            #expect(ContinuousClock.now < deadline, "Bedingung nicht erreicht")
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
