import SwiftUI
import Testing
@testable import GrantryCharts

/// Zusagen des Design-Standards „Lagebild“ (docs/design/instrumententafel.md): Kontraste der Farbreihe, Füllung der
/// Spur, Verteilung der Messfelder und Lage der Echos im Radar.
@Suite struct InstrumentDesignTests {
    private static func scaled(_ hue: InstrumentHue, _ factor: Double) -> Contrast.RGB {
        (hue.base.red * factor, hue.base.green * factor, hue.base.blue * factor)
    }

    private static let white = Contrast.white
    private static let darkPanel = InstrumentSurface.panelDark

    /// Flächen: Panel, Grund, gewählte Zeile, Mulde (6 % Vordergrund) im Panel und – nur für Grafik und sekundären Text
    /// (Umschalter, Suchfeld) – Mulde auf dem Grund.
    private static func grounds(dark: Bool, includingWellOnBackground: Bool = true) -> [Contrast.RGB] {
        let panel = dark ? InstrumentSurface.panelDark : InstrumentSurface.panelLight
        let background = dark ? InstrumentSurface.backgroundDark : InstrumentSurface.backgroundLight
        let ink = dark ? Contrast.white : Contrast.black
        let grounds = [panel, background, InstrumentSurface.selectionRGB(dark: dark),
                       Contrast.mix(ink, opacity: InstrumentOpacity.well, over: panel)]
        return grounds + (includingWellOnBackground ? [Contrast.mix(ink, opacity: InstrumentOpacity.well, over: background)] : [])
    }

    /// §2.3: Grafik ≥ 3 : 1 und kleiner Text ≥ 4,5 : 1 auf Weiß, dunkel ≥ 4,5 : 1 auf dem Panel.
    @Test(arguments: InstrumentHue.allCases)
    func hueMeetsContrast(_ hue: InstrumentHue) {
        #expect(Contrast.ratio(Self.scaled(hue, 0.62), Self.white) >= 3)
        #expect(Contrast.ratio(Self.scaled(hue, 0.5), Self.white) >= 4.5)
        #expect(Contrast.ratio(Self.scaled(hue, 1), Self.darkPanel) >= 4.5)
    }

    /// Schrift auf Hitze-Zellen (Tabellen, Kern-Kacheln) über die ganze Hitze ≥ 4,5 : 1 – hell schwarz, auch bei
    /// „Kontrast erhöhen“, dunkel weiß, über Panel und gewählter Zeile; dunkel bleibt die Hitze sichtbar.
    @Test(arguments: InstrumentHue.allCases)
    func heatTextMeetsContrast(_ hue: InstrumentHue) {
        #expect(HeatShade.opacity(forHeat: 1, hue: hue, dark: true) >= 0.35)
        for step in 0...20 {
            let heat = Double(step) / 20
            let dark = HeatShade.opacity(forHeat: heat, hue: hue, dark: true)
            #expect(HeatShade.textContrast(on: hue, opacity: dark, text: Contrast.white) >= 4.5, "dunkel, Hitze \(heat)")
            let light = HeatShade.opacity(forHeat: heat, hue: hue, dark: false)
            for factor in [0.62, 0.42] {
                for ground in [InstrumentSurface.panelLight, InstrumentSurface.selectionRGB(dark: false)] {
                    let cell = Contrast.mix(Self.scaled(hue, factor), opacity: light, over: ground)
                    #expect(Contrast.ratio(Contrast.black, cell) >= 4.5, "hell, Hitze \(heat), Faktor \(factor)")
                }
            }
        }
    }

    /// Zustandstöne: als Text ≥ 4,5 : 1 und als Grafik ≥ 3 : 1 auf allen Flächen beider Erscheinungsbilder.
    @Test(arguments: StatusTone.allCases.filter { $0 != .neutral })
    func statusTonesMeetContrast(_ tone: StatusTone) throws {
        for dark in [false, true] {
            let text = try #require(tone.rgb(dark: dark, text: true))
            let graphic = try #require(tone.rgb(dark: dark, text: false))
            for ground in Self.grounds(dark: dark, includingWellOnBackground: false) {
                #expect(Contrast.ratio(text, ground) >= 4.5, "Text \(tone) \(dark ? "dunkel" : "hell")")
            }
            for ground in Self.grounds(dark: dark) {
                #expect(Contrast.ratio(graphic, ground) >= 3, "Grafik \(tone) \(dark ? "dunkel" : "hell")")
            }
        }
    }

    /// Beschriftung eines Abschnitts im Thermikband (Chip-Tab): Textfarbe des Tons auf der Tönung des Tons (Chip-Deckkraft)
    /// über dem Panel ≥ 4,5 : 1.
    @Test(arguments: StatusTone.allCases.filter { $0 != .neutral })
    func statusTextOnTintedSegmentMeetsContrast(_ tone: StatusTone) throws {
        for dark in [false, true] {
            let text = try #require(tone.rgb(dark: dark, text: true))
            let graphic = try #require(tone.rgb(dark: dark, text: false))
            let panel = dark ? InstrumentSurface.panelDark : InstrumentSurface.panelLight
            let ground = Contrast.mix(graphic, opacity: InstrumentOpacity.chip, over: panel)
            #expect(Contrast.ratio(text, ground) >= 4.5, "\(tone) \(dark ? "dunkel" : "hell")")
        }
    }

    /// Sekundärer Text (`instrumentSecondary`) ≥ 4,5 : 1 auf allen Flächen; das System-`.secondary` schaffte hell nur
    /// etwa 3 : 1.
    @Test func secondaryTextMeetsContrast() {
        for dark in [false, true] {
            let ink = dark ? Contrast.white : Contrast.black
            for ground in Self.grounds(dark: dark) {
                let text = Contrast.mix(ink, opacity: InstrumentOpacity.secondaryText, over: ground)
                #expect(Contrast.ratio(text, ground) >= 4.5, "\(dark ? "dunkel" : "hell")")
            }
        }
    }

    /// Thermikband im Wachbuch (TM-12.5): „normal“ ist eine ruhige Bahn; mit „Kontrast erhöhen“ hebt sie sich als Grafik
    /// ≥ 3 : 1 vom Panel ab – auch dort bleibt ungemessen (leer) von normal unterscheidbar.
    @Test func quietStateBandStandsOutWithIncreasedContrast() {
        for dark in [false, true] {
            let panel = dark ? InstrumentSurface.panelDark : InstrumentSurface.panelLight
            let band = Contrast.mix(dark ? Contrast.white : Contrast.black, opacity: InstrumentOpacity.quietBandIncreased,
                                    over: panel)
            #expect(Contrast.ratio(band, panel) >= 3, "\(dark ? "dunkel" : "hell")")
            #expect(InstrumentOpacity.quietBand < InstrumentOpacity.quietBandIncreased)
        }
    }

    /// Bernstein ist dem Befund vorbehalten: keine Messgröße liegt im Orange-Gelb-Bereich.
    @Test(arguments: InstrumentHue.allCases)
    func noMeasureLooksLikeAmber(_ hue: InstrumentHue) {
        let (red, green, blue) = (hue.base.red, hue.base.green, hue.base.blue)
        let amberLike = red > 0.9 && green > 0.55 && green < 0.8 && blue < 0.3
        #expect(!amberLike)
    }

    @Test func spurFillsAtLeastItsHeightOnceAboveZero() {
        #expect(Spur.filledWidth(fraction: nil, width: 100, height: 6) == 0)
        #expect(Spur.filledWidth(fraction: 0, width: 100, height: 6) == 0)
        #expect(Spur.filledWidth(fraction: 0.001, width: 100, height: 6) == 6)
        #expect(Spur.filledWidth(fraction: 0.5, width: 100, height: 6) == 50)
        #expect(Spur.filledWidth(fraction: 1, width: 100, height: 6) == 100)
    }

    /// Mangel 11 der Bewertung 2026.11.7: nie ein einzelnes Feld allein in einer zweiten Reihe.
    @Test func measureFieldsShareRowsEvenly() {
        #expect(MeasureFieldRow.columns(for: 0) == 1)
        #expect(MeasureFieldRow.columns(for: 3) == 3)
        #expect(MeasureFieldRow.columns(for: 6) == 6)
        #expect(MeasureFieldRow.columns(for: 7) == 4)
        #expect(MeasureFieldRow.columns(for: 8) == 4)
    }

    /// Im schmalen Panel weicht die Reihe auf weniger Spalten aus, statt Titel abzuschneiden; nie unter zwei.
    @Test func measureFieldsFallBackToFewerColumns() {
        #expect(MeasureFieldRow.columnOptions(for: 6) == [6, 3, 2])
        #expect(MeasureFieldRow.columnOptions(for: 5) == [5, 3, 2])
        #expect(MeasureFieldRow.columnOptions(for: 8) == [4, 2])
        #expect(MeasureFieldRow.columnOptions(for: 2) == [2])
        #expect(MeasureFieldRow.columnOptions(for: 1) == [1])
        // Akku in „Energie“ (336 pt): zwei Spalten statt sechs gekürzter Titel; „Leistung“ (690 pt) in einer Reihe.
        #expect(MeasureFieldGrid(count: 6).columns(width: 336) == 2)
        #expect(MeasureFieldGrid(count: 5).columns(width: 690) == 5)
        #expect(MeasureFieldGrid(count: 6).columns(width: .infinity) == 6)
    }

    @Test func radarSummarizesCrowdedRingsAndKeepsTheTopFree() {
        let echoes = (0..<12).map { ReachRadar.Echo(id: "\($0)", label: "p\($0)", ring: .network) }
            + [ReachRadar.Echo(id: "local", label: "postgres", ring: .thisMac)]
        let placed = ReachRadar.placed(echoes)
        let network = placed.filter { $0.echo.ring == .network }
        #expect(network.count == ReachRadar.maximumPerRing)
        #expect(network.last?.echo.label == "+5")
        // Oben (um 270°) steht der Titel des Rings.
        #expect(placed.allSatisfy { !(255...285).contains($0.degrees) })
    }

    /// Rechte-Schichten: Jeder Ring fasst nach seiner eigenen Grenze zusammen – innen weniger, weil der Ring kürzer ist.
    @Test func ringRadarSummarizesEachRingAtItsOwnCapacity() {
        let rings = [RingRadar.Ring(title: "innen", capacity: 3), RingRadar.Ring(title: "außen", capacity: 12)]
        let echoes = (0..<5).map { RingRadar.Echo(id: "i\($0)", label: "i\($0)", ring: 0) }
            + (0..<12).map { RingRadar.Echo(id: "a\($0)", label: "a\($0)", ring: 1, tone: .finding) }
        let placed = RingRadar.placed(echoes, rings: rings)
        let inner = placed.filter { $0.echo.ring == 0 }
        let outer = placed.filter { $0.echo.ring == 1 }
        #expect(inner.map(\.echo.label) == ["i0", "i1", "+3"])
        #expect(outer.count == 12)
        #expect(outer.last?.echo.label == "a11")
        // Das Sammel-Echo trägt den Ton seines Rings, nicht den eines zusammengefassten Echos.
        #expect(inner.last?.echo.tone == nil)
        #expect(placed.allSatisfy { !(255...285).contains($0.degrees) })
    }

    /// Ringe gleichmäßig von innen (0,34) bis außen (0,93); ein einzelner Ring liegt außen.
    @Test func ringRadarSpacesRingsEvenly() {
        #expect(RingRadar.scale(ring: 0, of: 4) == 0.34)
        #expect(abs(RingRadar.scale(ring: 2, of: 3) - 0.93) < 1e-9)
        #expect(abs(RingRadar.scale(ring: 1, of: 3) - 0.635) < 1e-9)
        #expect(RingRadar.scale(ring: 0, of: 1) == 0.93)
    }

    /// Rechte-Schichten: außen ab 12 Echos zusammengefasst, innen im Verhältnis des kürzeren Rings früher.
    @Test func ringRadarCapacityFollowsCircumference() {
        #expect((0..<4).map { RingRadar.proportionalCapacity(ring: $0, of: 4, outermost: 12) } == [4, 7, 9, 12])
        #expect(RingRadar.proportionalCapacity(ring: 0, of: 1, outermost: 12) == 12)
    }

    /// Echos außerhalb der Ringe fallen weg, statt einen Ring vorzutäuschen.
    @Test func ringRadarDropsEchoesWithoutRing() {
        let placed = RingRadar.placed([RingRadar.Echo(id: "x", label: "x", ring: 5)],
                                      rings: [RingRadar.Ring(title: "einzig", capacity: 4)])
        #expect(placed.isEmpty)
    }
}
