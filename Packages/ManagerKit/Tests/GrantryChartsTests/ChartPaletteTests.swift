import Testing
@testable import GrantryCharts

@Suite struct ChartPaletteTests {
    @Test func endpointsMatchStops() {
        let palette = ChartPalette.standard
        #expect(palette.rgb(forLoad: 0) == palette.stops[0].color)
        #expect(palette.rgb(forLoad: 1) == palette.stops[palette.stops.count - 1].color)
    }

    @Test func loadOutsideRangeIsClamped() {
        #expect(ChartPalette.highContrast.rgb(forLoad: -3) == ChartPalette.highContrast.rgb(forLoad: 0))
        #expect(ChartPalette.highContrast.rgb(forLoad: .nan) == ChartPalette.highContrast.rgb(forLoad: 0))
    }

    @Test func midpointMixesNeighbours() {
        let mid = ChartPalette.colorblindSafe.rgb(forLoad: 0.5)
        #expect(abs(mid.red - 0.47) < 1e-9)
    }

    @Test func accessibilityOverridesPalette() {
        let contrast = ChartStyle.resolve(reduceMotion: false, increasedContrast: true, differentiateWithoutColor: true)
        #expect(contrast.palette(.efficiency) == .highContrast)
        #expect(!contrast.glows)
        let colorblind = ChartStyle.resolve(reduceMotion: true, increasedContrast: false, differentiateWithoutColor: true)
        #expect(colorblind.palette(.standard) == .colorblindSafe)
        #expect(!colorblind.animates)
        let standard = ChartStyle.resolve(reduceMotion: false, increasedContrast: false, differentiateWithoutColor: false)
        #expect(standard.palette(.efficiency) == .efficiency && standard.glows && standard.animates)
    }
}
