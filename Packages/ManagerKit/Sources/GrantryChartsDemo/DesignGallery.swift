import GrantryCharts
import SwiftUI

/// Galerie des Design-Standards „Instrumententafel“, Gestaltung „Lagebild“ (`docs/design/instrumententafel.md`): Tokens
/// und Bausteine aus GrantryCharts mit festen Beispieldaten, ohne Zufall und Uhr. Bilder für `docs/design/galerie`:
/// `GRANTRY_DEMO_DESIGN=<Ordner> swift run --package-path Packages/ManagerKit GrantryChartsDemo`.
struct DesignGallery: View {
    enum Page: String, CaseIterable, Sendable {
        case tokens, components
    }

    let page: Page

    var body: some View {
        Group {
            switch page {
            case .tokens: TokenBoard()
            case .components: ComponentBoard()
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: 1400, alignment: .topLeading)
        .instrumentBackground()
    }
}

// MARK: - Beispieldaten

/// Feste Verläufe wie in den Snapshot-Tests: gleicher Zeitpunkt, keine Zufallswerte.
enum GallerySamples {
    static let latest = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func series(_ value: (Double) -> Double) -> ChartSeries {
        ChartSeries(values: (0..<61).map { value(Double($0)) }, spacing: 1, latest: latest)
    }

    static let cpu = series { min(1, 0.32 + 0.16 * sin($0 / 5) + ($0 > 44 && $0 < 54 ? 0.3 : 0)) }
    static let efficiency = series { 0.22 + 0.1 * cos($0 / 4) }
    static let power = series { 6 + 2.5 * sin($0 / 7) + ($0 > 44 ? 5 : 0) }
    static let memory = series { 0.36 + 0.02 * sin($0 / 9) }
    static let received = series { 2.4e6 + 1.6e6 * sin($0 / 6) }
    static let sent = series { 0.9e6 + 0.5e6 * cos($0 / 5) }

    static let cores: [CoreGrid.Core] = (4...9).map { index in
        CoreGrid.Core(id: index, series: series { min(1, max(0, 0.35 + 0.3 * sin($0 / 4 + Double(index)))) })
    }

    static let echoes: [ReachRadar.Echo] = [
        .init(id: "1", label: "postgres :5432", ring: .thisMac), .init(id: "2", label: "launchd :8021", ring: .thisMac),
        .init(id: "3", label: "mDNSResponder :5353", ring: .localNetwork),
        .init(id: "4", label: "node :3000", ring: .network), .init(id: "5", label: "rapportd :49178", ring: .network),
    ]
}

private extension InstrumentHue {
    var galleryTitle: String {
        switch self {
        case .cpu: "CPU · Leistungskerne"
        case .efficiencyCores: "Effizienzkerne"
        case .memory: "Arbeitsspeicher"
        case .diskRead: "Datenträger lesen"
        case .diskWrite: "Datenträger schreiben"
        case .received: "Netz · empfangen"
        case .sent: "Netz · gesendet"
        case .gpu: "GPU"
        case .power: "Leistung (W)"
        case .battery: "Akku"
        case .neuralEngine: "Neural Engine"
        }
    }
}

// MARK: - Rahmen

private struct GalleryHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
            Text(verbatim: title).font(InstrumentFont.display)
            Text(verbatim: subtitle).font(InstrumentFont.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Abschnitt mit Peilkopf und Inhalt in einem Panel.
private struct GallerySection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(title, detail: note)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .instrumentPanel()
    }
}

private struct SwatchLabel: View {
    let title: String
    let token: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title).font(InstrumentFont.label.weight(.semibold))
            Text(verbatim: token).font(InstrumentFont.micro.monospaced()).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}

// MARK: - Tokens

private struct TokenBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            GalleryHeader(title: "Lagebild · Tokens",
                          subtitle: "Flächen, Marke, Farbe je Messgröße, Zustandstöne, Typografie, Abstände, Radien, Linien")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                VStack(spacing: InstrumentSpacing.panel) {
                    SurfaceSection()
                    ToneSection()
                }
                .frame(width: 520)
                HueSection()
            }
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                TypographySection()
                ScaleSection()
            }
        }
    }
}

private struct SurfaceSection: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GallerySection(title: "Flächen und Marke", note: "Nachtblau, Panels, Auswahl im Grantry-Verlauf, Befund in Bernstein") {
            Grid(horizontalSpacing: InstrumentSpacing.cell, verticalSpacing: InstrumentSpacing.cell) {
                GridRow {
                    swatch("Grund", token: "surface.ground") {
                        Rectangle().fill(InstrumentSurface.background(colorScheme))
                    }
                    swatch("Panel", token: "surface.panel") { Color.clear.instrumentPanel(padding: 0) }
                    swatch("Auswahl", token: "surface.selection") {
                        Color.clear.instrumentRowBackground(isSelected: true)
                    }
                }
                GridRow {
                    swatch("Fokus", token: "brand.focus") { Color.clear.instrumentPanel(padding: 0, focused: true) }
                    swatch("Markenfläche", token: "brand.fill") { Capsule().fill(GrantryBrand.fill) }
                    swatch("Befund", token: "brand.amber") {
                        HStack(spacing: InstrumentSpacing.group) {
                            FindingDot()
                            ShieldBadge(finding: true, size: 30)
                        }
                    }
                }
            }
        }
    }

    private func swatch(_ title: String, token: String, @ViewBuilder sample: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            sample().frame(width: 140, height: 40)
            SwatchLabel(title: title, token: token)
        }
    }
}

private struct HueSection: View {
    @Environment(\.self) private var environment

    var body: some View {
        GallerySection(title: "Farbe je Messgröße",
                       note: "Ring, Linie und Spur in der Grafikfarbe; Werte in der Textfarbe (hell dunkler)") {
            Grid(alignment: .leading, horizontalSpacing: InstrumentSpacing.page, verticalSpacing: InstrumentSpacing.item) {
                ForEach(InstrumentHue.allCases, id: \.self) { hue in
                    GridRow {
                        PeilRing(fraction: 0.62, hue: hue).frame(width: InstrumentSize.peilRing,
                                                                 height: InstrumentSize.peilRing)
                        Text(verbatim: hue.galleryTitle).font(InstrumentFont.body)
                        Spur(fraction: 0.62, color: environment.instrumentColor(hue))
                            .frame(width: 140, height: InstrumentSize.spurList)
                        Text(verbatim: "63,4 %").font(InstrumentFont.tileValue)
                            .foregroundStyle(environment.instrumentTextColor(hue))
                        HeatCell("12,3 %", heat: 0.7, hue: hue).frame(width: 90)
                    }
                }
            }
        }
    }
}

private struct ToneSection: View {
    var body: some View {
        GallerySection(title: "Zustandstöne", note: "Für Zustände, nie für Messgrößen – immer mit Text") {
            HStack(spacing: InstrumentSpacing.item) {
                ForEach(StatusTone.allCases, id: \.self) { tone in
                    StatusChip(Self.title(tone), tone: tone)
                }
            }
        }
    }

    private static func title(_ tone: StatusTone) -> String {
        switch tone {
        case .positive: "läuft"
        case .info: "bereit"
        case .finding: "auffällig"
        case .critical: "Fehler"
        case .neutral: "beendet"
        }
    }
}

private struct TypographySection: View {
    private struct Role: Identifiable {
        let name: String
        let font: Font
        let sample: String
        var id: String { name }
    }

    private let roles = [
        Role(name: "display", font: InstrumentFont.display, sample: "Apple M4 Max"),
        Role(name: "verdict", font: InstrumentFont.verdict, sample: "Ruhig"),
        Role(name: "bigNumber", font: InstrumentFont.bigNumber, sample: "182"),
        Role(name: "valueLarge", font: InstrumentFont.valueLarge, sample: "63,4 %"),
        Role(name: "value", font: InstrumentFont.value, sample: "8,10 W"),
        Role(name: "title", font: InstrumentFont.title, sample: "Leistungskerne"),
        Role(name: "tileValue", font: InstrumentFont.tileValue, sample: "1,3 MB/s"),
        Role(name: "body", font: InstrumentFont.body, sample: "Safari · Programm"),
        Role(name: "code", font: InstrumentFont.code, sample: "192.168.1.24:52411"),
        Role(name: "label", font: InstrumentFont.label, sample: "Offene Sockets"),
        Role(name: "micro", font: InstrumentFont.micro, sample: "CPU 4 · 100 %"),
    ]

    var body: some View {
        GallerySection(title: "Typografie", note: "Textstile des Systems, große Werte in SF Rounded") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: InstrumentSpacing.page,
                 verticalSpacing: InstrumentSpacing.inline) {
                ForEach(roles) { role in
                    GridRow {
                        Text(verbatim: role.name).font(InstrumentFont.label.monospaced()).foregroundStyle(.secondary)
                        Text(verbatim: role.sample).font(role.font).lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct ScaleSection: View {
    private let spacing: [(String, CGFloat)] = [
        ("stack", InstrumentSpacing.stack), ("inline", InstrumentSpacing.inline), ("item", InstrumentSpacing.item),
        ("group", InstrumentSpacing.group), ("cell", InstrumentSpacing.cell), ("panel", InstrumentSpacing.panel),
        ("page", InstrumentSpacing.page), ("bar", InstrumentSpacing.bar), ("empty", InstrumentSpacing.empty),
    ]
    private let radii: [(String, CGFloat)] = [
        ("graph", InstrumentRadius.graph), ("control", InstrumentRadius.control), ("block", InstrumentRadius.block),
        ("card", InstrumentRadius.card), ("panel", InstrumentRadius.panel),
    ]

    var body: some View {
        GallerySection(title: "Abstände und Radien", note: "Skala in pt; Radien continuous") {
            HStack(alignment: .top, spacing: InstrumentSpacing.empty) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                    ForEach(spacing, id: \.0) { name, value in
                        HStack(spacing: InstrumentSpacing.group) {
                            Capsule().fill(GrantryBrand.fill).frame(width: value * 4, height: 8)
                                .frame(width: 100, alignment: .leading)
                            Text(verbatim: "\(name) \(Int(value))").font(InstrumentFont.label.monospaced())
                        }
                    }
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
                    ForEach(radii, id: \.0) { name, value in
                        HStack(spacing: InstrumentSpacing.group) {
                            RoundedRectangle(cornerRadius: value, style: .continuous)
                                .strokeBorder(.primary.opacity(0.4), lineWidth: InstrumentStroke.border)
                                .frame(width: 64, height: 30)
                            Text(verbatim: "\(name) \(Int(value))").font(InstrumentFont.label.monospaced())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Bausteine

private struct ComponentBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            GalleryHeader(title: "Lagebild · Bausteine",
                          subtitle: "Lagezeile, Zustandszeile, Peilkopf, Bogen, Spur, Graph, Karten, Tabelle, Radar, Umschalter")
            VerdictBar(verdict: "1 Prozess auffällig",
                       reason: "photoanalysisd belegt seit mindestens einer Minute mehr als 80 % eines Kerns.",
                       finding: true,
                       items: [StatusItem("1 Prozess auffällig", tone: .finding),
                               StatusItem("Speicherdruck normal", tone: .positive),
                               StatusItem("Thermik normal", tone: .positive)],
                       facts: "Takt 1 s · 642 Prozesse · 2.814 Threads · Laufzeit 3:04:17")
            StatusLine(verdict: "Ruhig", finding: false, items: [StatusItem("Speicherdruck normal", tone: .positive)],
                       facts: "Takt 1 s · 642 Prozesse · Laufzeit 3:04:17")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                GaugeSection()
                CardSection().frame(width: 380)
            }
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                GraphSection()
                RadarSection().frame(width: InstrumentSize.columnRadar)
            }
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                TableSection()
                ControlSection().frame(width: 420)
            }
        }
    }
}

private struct GaugeSection: View {
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            ForEach([(InstrumentHue.cpu, "CPU", 0.63, "63 %"), (.memory, "Arbeitsspeicher", 0.37, "37 %"),
                     (.power, "Leistung", 0.41, "8,1 W"), (.gpu, "GPU", 0.18, "18 %")], id: \.1) { hue, title, fraction, value in
                ArcGauge(fraction: fraction, color: environment.instrumentColor(hue),
                         textColor: environment.instrumentTextColor(hue), value: value, caption: title)
                    .frame(height: InstrumentSize.arcGauge)
                    .frame(maxWidth: .infinity)
                    .instrumentPanel(padding: InstrumentSpacing.cell)
            }
        }
    }
}

private struct CardSection: View {
    @Environment(\.self) private var environment

    var body: some View {
        VStack(spacing: InstrumentSpacing.group) {
            MeasureCard(title: "CPU", detail: "12 P · 4 E", value: "63 %", hue: .cpu, fraction: 0.63, isSelected: true)
            MeasureCard(title: "WLAN", detail: "en0", value: "1,7 MB/s", hue: .received, fraction: 0.12) {
                MirrorGraph(upper: GallerySamples.received, lower: GallerySamples.sent,
                            colors: (environment.instrumentColor(.received), environment.instrumentColor(.sent)),
                            showsGrid: false)
                    .frame(height: InstrumentSize.cardGraph)
            }
            HStack(spacing: InstrumentSpacing.group) {
                CountTile(title: "Läuft", value: 182, detail: "von 412 Diensten", tone: .positive, fraction: 0.44)
                CountTile(title: "Fehler", value: 2, tone: .critical, fraction: 0.01)
            }
        }
    }
}

private struct GraphSection: View {
    @Environment(\.self) private var environment

    var body: some View {
        let cpu = environment.instrumentColor(.cpu)
        let power = environment.instrumentColor(.power)
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            PeilHead("Verlauf", detail: "letzte 60 Sekunden, gemeinsame Zeitachse")
            VerlaufLane(title: "CPU", value: "63 %", hue: .cpu) {
                LiveGraph(series: GallerySamples.cpu,
                          overlays: [.init(series: GallerySamples.efficiency, scale: .fixed(0...1),
                                           color: environment.instrumentColor(.efficiencyCores)),
                                     .init(series: GallerySamples.power, scale: .automatic(minimum: 5), color: power)],
                          color: cpu, isInteractive: false)
            }
            VerlaufLane(title: "Arbeitsspeicher", value: "17,8 GB", hue: .memory) {
                LiveGraph(series: GallerySamples.memory, color: environment.instrumentColor(.memory), isInteractive: false)
            }
            VerlaufLane(title: "WLAN", value: "↓ 2,4 · ↑ 0,9 MB/s", hue: .received) {
                MirrorGraph(upper: GallerySamples.received, lower: GallerySamples.sent,
                            colors: (environment.instrumentColor(.received), environment.instrumentColor(.sent)))
            }
            HStack(spacing: InstrumentSpacing.page) {
                LegendItem(title: "Auslastung", hue: .cpu)
                LegendItem(title: "Effizienzkerne", hue: .efficiencyCores)
                LegendItem(title: "Leistung", hue: .power)
                Spacer()
                TimeAxisLabels(window: 60).frame(maxWidth: InstrumentSize.columnWide)
            }
        }
        .frame(height: 360)
        .instrumentPanel()
    }
}

private struct RadarSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead("Erreichbarkeit", detail: "Wer diesen Mac erreichen kann", value: "2", finding: true)
            ReachRadar(echoes: GallerySamples.echoes).frame(height: InstrumentSize.radar)
        }
        .instrumentPanel()
    }
}

private struct TableSection: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: InstrumentSpacing.inline) {
                HeatColumnHeader(title: "Name", value: "642 Prozesse", heat: nil, sortAscending: nil, alignment: .leading)
                ForEach([("CPU", "38 %", 0.38, InstrumentHue.cpu, false), ("Speicher", "21,4 GB", 0.67, .memory, true),
                         ("Netz", "1,2 MB/s", 0.12, .received, true)], id: \.0) { title, value, heat, hue, plain in
                    HeatColumnHeader(title: title, value: value, heat: heat, sortAscending: plain ? nil : false, hue: hue)
                        .frame(width: 108)
                }
            }
            .padding(.horizontal, InstrumentSpacing.bar)
            .padding(.vertical, InstrumentSpacing.cell)
            Divider()
            VStack(spacing: InstrumentSpacing.stack) {
                row("photoanalysisd", cells: [("15,5 %", 0.62), ("640 MB", 0.3), ("0 B/s", 0)], selected: false)
                row("Safari", cells: [("8,4 %", 0.34), ("1,6 GB", 0.8), ("1,2 MB/s", 0.4)], selected: true)
                row("mds_stores", cells: [("2,1 %", 0.08), ("210 MB", 0.1), ("0 B/s", 0)], selected: false)
            }
            .padding(InstrumentSpacing.group)
        }
        .instrumentPanel(padding: 0)
    }

    private func row(_ name: String, cells: [(String, Double)], selected: Bool) -> some View {
        let hues: [InstrumentHue] = [.cpu, .memory, .received]
        return HStack(spacing: InstrumentSpacing.inline) {
            Text(verbatim: name).font(InstrumentFont.body).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, InstrumentSpacing.group)
            ForEach(cells.indices, id: \.self) { index in
                HeatCell(cells[index].0, heat: cells[index].1, hue: hues[index]).frame(width: 108)
            }
        }
        .instrumentRowBackground(isSelected: selected)
    }
}

private struct ControlSection: View {
    @State private var window = "60 s"

    var body: some View {
        GallerySection(title: "Umschalter, Chips, Kennzahlen", note: "gewählt im Grantry-Verlauf") {
            VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
                InstrumentSegments("Zeitraum", selection: $window,
                                   options: [("60 s", "60 s"), ("5 min", "5 min"), ("15 min", "15 min")])
                HStack(spacing: InstrumentSpacing.item) {
                    StatusChip("läuft", tone: .positive)
                    StatusChip("aus dem Netz", tone: .finding)
                    StatusChip("Du", tone: .info, isSmall: true)
                }
                MeasureFieldRow(fields: [("Auslastung", "63,4 %"), ("Geschwindigkeit", "3,2 GHz"), ("Threads", "–")])
            }
        }
    }
}

#Preview("Tokens") {
    ScrollView { DesignGallery(page: .tokens) }
}

#Preview("Bausteine") {
    ScrollView { DesignGallery(page: .components) }
}
