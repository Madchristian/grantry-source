import Foundation
import Testing
@testable import GrantryCharts

@Suite struct NiceScaleTests {
    @Test(arguments: [(0.3, 1.0), (1.0, 1.0), (1.2, 2.0), (3.0, 5.0), (7.0, 10.0), (42_000_000.0, 50_000_000.0)])
    func ceilingRoundsUpToNiceSteps(value: Double, expected: Double) {
        #expect(NiceScale.ceiling(value) == expected)
    }

    @Test func ceilingRespectsMinimum() {
        #expect(NiceScale.ceiling(0, minimum: 1_000_000) == 1_000_000)
    }

    @Test func automaticScaleUsesVisibleMaximum() {
        #expect(ChartScale.automatic(minimum: 1).upperBound(for: [3, nil, 1.5]) == 5)
        #expect(ChartScale.fixed(0...1).upperBound(for: [3]) == 1)
    }
}
