import Testing
@testable import GrantryCharts

@Suite struct UsageBarLayoutTests {
    @Test func fractionsUseNiceUpperBound() {
        let layout = UsageBarLayout(values: [0, 5, 10])
        #expect(layout.upperBound == 10)
        #expect(layout.fractions == [0, 0.5, 1])
    }

    @Test func upperBoundRoundsUp() {
        let layout = UsageBarLayout(values: [3])
        #expect(layout.upperBound == 5)
        #expect(layout.fractions == [0.6])
    }

    @Test func emptyOrZeroValuesStayFlat() {
        #expect(UsageBarLayout(values: []).fractions.isEmpty)
        #expect(UsageBarLayout(values: [0, 0]).fractions == [0, 0])
    }

    @Test func negativeOrInvalidValuesCountAsZero() {
        #expect(UsageBarLayout(values: [-1, .nan, 2]).fractions == [0, 0, 1])
    }

    @Test func gridLinesDivideUpperBound() {
        #expect(UsageBarLayout(values: [10]).gridFractions == [0.25, 0.5, 0.75, 1])
    }
}
