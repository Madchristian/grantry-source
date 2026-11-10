import Foundation
import Testing
@testable import GrantryCharts

@Suite struct ChartAccessibilityTests {
    @Test func detectsTrend() {
        let rising: [Double?] = [0.1, 0.1, 0.1, 0.1, 0.1, 0.5, 0.5, 0.5, 0.5, 0.5]
        #expect(ChartAccessibility.trend(of: rising, tolerance: 0.05) == .rising)
        #expect(ChartAccessibility.trend(of: rising.reversed(), tolerance: 0.05) == .falling)
        #expect(ChartAccessibility.trend(of: Array(repeating: 0.3, count: 10), tolerance: 0.05) == .steady)
    }

    @Test func tooFewValuesAreSteady() {
        #expect(ChartAccessibility.trend(of: [0.1, 0.9], tolerance: 0.05) == .steady)
    }
}
