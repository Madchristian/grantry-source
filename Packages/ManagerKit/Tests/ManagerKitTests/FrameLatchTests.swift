import Foundation
import Observation
import Testing
@testable import ManagerKit

/// Werte eigener Messungen (Sensoren, ps) erst zum Messtakt (#481): Jede Änderung, die eine Ansicht des Task-Managers
/// liest, wertet sie samt Layout neu aus; ungetaktet waren das in „Übersicht“ fast zwei Durchläufe je Takt.
@MainActor
@Suite struct FrameLatchTests {
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private func observesChange(of latch: FrameLatch<Int>, during change: () -> Void) -> Bool {
        let changed = Flag()
        withObservationTracking { _ = latch.value } onChange: { changed.isSet = true }
        change()
        return changed.isSet
    }

    @Test func keepsValueUntilANewOneIsOffered() {
        let latch = FrameLatch(1) { $0 != $1 }
        #expect(observesChange(of: latch) { latch.offer(2) })
        #expect(latch.value == 2)
    }

    @Test func ignoresAnOfferThatIsNotNew() {
        let latch = FrameLatch(1) { $0 != $1 }
        #expect(!observesChange(of: latch) { latch.offer(1) })
        #expect(latch.value == 1)
    }
}
