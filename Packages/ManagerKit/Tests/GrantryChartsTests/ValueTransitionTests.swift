import Testing
@testable import GrantryCharts

/// Übergänge je Takt (Leistungsbudget Spec §4): Kleine Schwankungen lösen keine Animation aus, deutliche nur kurz – sonst
/// liefe bei 1 s Takt fast ununterbrochen eine Animation mit der Bildwiederholrate.
@Suite struct ValueTransitionTests {
    @Test func smallChangesKeepTheStep() {
        #expect(ValueTransition.step(0.31) == ValueTransition.step(0.34))
        #expect(ValueTransition.step(0.0) == ValueTransition.step(0.04))
        #expect(ValueTransition.step(0.96) == ValueTransition.step(1))
    }

    @Test func clearChangesSwitchTheStep() {
        #expect(ValueTransition.step(0.2) != ValueTransition.step(0.32))
        #expect(ValueTransition.step(0.05) != ValueTransition.step(0.9))
    }

    @Test func outOfRangeAndNonFiniteValuesAreClamped() {
        #expect(ValueTransition.step(-0.5) == 0)
        #expect(ValueTransition.step(.nan) == 0)
        #expect(ValueTransition.step(.infinity) == 0)
        #expect(ValueTransition.step(7) == ValueTransition.step(1))
    }

    /// Ein Übergang belegt höchstens ein Drittel des Standardtakts (1 s) und endet auch beim kürzesten (0,5 s) vor dem
    /// nächsten.
    @Test func transitionEndsWellBeforeTheNextTick() {
        #expect(ValueTransition.duration <= 1.0 / 3)
        #expect(ValueTransition.duration < 0.5)
    }
}
