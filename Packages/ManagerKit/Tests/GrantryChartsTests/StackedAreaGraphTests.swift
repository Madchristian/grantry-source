import Foundation
import Testing
@testable import GrantryCharts

@Suite struct StackedAreaGraphTests {
    @Test func stackedLayersAccumulate() {
        let date = Date()
        let layers = [ChartSeries(values: [1, 2], spacing: 1, latest: date),
                      ChartSeries(values: [3, nil], spacing: 1, latest: date)]
        #expect(StackedAreaGraph.stacked(layers).map(\.values) == [[1, 2], [4, nil]])
    }
}
