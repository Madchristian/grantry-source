import Testing
@testable import GrantryCharts

/// Hitze (§2.6): Deckkraft der Messgrößenfarbe nach Last, dunkel unter Schrift begrenzt je Messgröße.
@Suite struct HeatCellTests {
    @Test func noHeatIsTransparent() {
        #expect(HeatShade.opacity(forHeat: 0, dark: false) == 0)
        #expect(HeatShade.opacity(forHeat: .nan, dark: true) == 0)
    }

    @Test func opacityGrowsWithHeatAndIsStrongerInDarkMode() {
        let light = HeatShade.opacity(forHeat: 1, dark: false)
        let dark = HeatShade.opacity(forHeat: 1, dark: true)
        #expect(abs(light - 0.55) < 1e-9)
        #expect(abs(dark - 0.7) < 1e-9)
        #expect(HeatShade.opacity(forHeat: 0.5, dark: false) < light)
        #expect(HeatShade.opacity(forHeat: 2, dark: false) == light)
    }

    /// Unter Schrift begrenzt dunkel die Messgröße die Deckkraft: helle Farben (Gelbgrün, Limette) bleiben blasser als
    /// dunkle (Koralle); hell gilt für alle derselbe Höchstwert.
    @Test func darkTextCellsStayBelowWhiteContrastLimit() {
        let battery = HeatShade.opacity(forHeat: 1, hue: .battery, dark: true)
        let power = HeatShade.opacity(forHeat: 1, hue: .power, dark: true)
        #expect(battery < power)
        #expect(power <= HeatShade.opacity(forHeat: 1, dark: true))
        #expect(HeatShade.opacity(forHeat: 1, hue: .battery, dark: false) == HeatShade.opacity(forHeat: 1, dark: false))
        #expect(HeatShade.opacity(forHeat: .nan, hue: .cpu, dark: true) == 0)
    }
}
