import AppKit
import SwiftUI
@testable import GrantryCharts

/// TM17 (Menüleiste: einstellbare Messanzeigen) mit festen Beispielwerten: Menüleiste, Einstellungs-Tab und Popover je
/// Element; Entwurf von Christian am 09.11.2026 abgenommen (E1–E4).
extension SnapshotGallery {
    enum MeterKind: String, CaseIterable {
        case overview, cpu, gpu, memory, network, disk, thermal, battery

        var title: String {
            switch self {
            case .overview: "Auslastung"
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .memory: "Arbeitsspeicher"
            case .network: "Netz"
            case .disk: "Datenträger"
            case .thermal: "Thermik"
            case .battery: "Akku"
            }
        }

        var styles: [GalleryMeterStyle] {
            switch self {
            case .overview: [.graphAndBar]
            case .cpu, .gpu, .memory: GalleryMeterStyle.matrix
            case .network, .disk: [.number, .graph, .numberAndGraph]
            case .thermal, .battery: [.number, .bar, .numberAndBar]
            }
        }

        var defaultStyle: GalleryMeterStyle {
            switch self {
            case .overview: .graphAndBar
            case .memory, .thermal, .battery: .numberAndBar
            case .cpu, .gpu: .numberAndGraph
            case .network, .disk: .number
            }
        }
    }

    static func last30(_ series: ChartSeries, scale: Double = 1) -> [Double?] {
        series.values.suffix(30).map { $0.map { $0 / scale } }
    }

    static let received = series { 1.2e6 + 0.9e6 * sin($0 / 4) + ($0 > 50 ? 2.4e6 : 0) }
    static let sent = series { 0.12e6 + 0.08e6 * cos($0 / 3) }
    static let memoryUsed = series { 0.61 + 0.02 * sin($0 / 8) }

    static func face(_ kind: MeterKind, style: GalleryMeterStyle? = nil, finding: Bool = false)
        -> MenuBarMeterFace {
        let style = style ?? kind.defaultStyle
        func make(_ tag: String?, _ lines: [String], _ widest: [String], trace: MenuBarMeterFace.Trace? = nil,
                  gauge: MenuBarMeterFace.Gauge? = nil) -> MenuBarMeterFace {
            MenuBarMeterFace(tag: tag, lines: lines, widest: widest, trace: trace, gauge: gauge,
                             showsNumber: style.showsNumber, showsGraph: style.showsGraph, showsBar: style.showsBar,
                             isFinding: finding)
        }
        let rates = ["999 KB/s", "9,9 MB/s", "999 MB/s"]
        switch kind {
        case .overview:
            return make(nil, [], [], trace: .single(last30(cpu)), gauge: .level(0.61))
        case .cpu:
            return make("CPU", ["38 %"], ["100 %"], trace: .single(last30(cpu)), gauge: .level(0.38))
        case .gpu:
            return make("GPU", ["16 %"], ["100 %"], trace: .single(last30(gpu)), gauge: .level(0.16))
        case .memory:
            return make("RAM", [finding ? "87 %" : "61 %"], ["100 %"], trace: .single(last30(memoryUsed)),
                        gauge: .level(finding ? 0.87 : 0.61))
        case .network:
            return make("NETZ", ["↓ 3,6 MB/s", "↑ 48 KB/s"], rates.map { "↓ \($0)" },
                        trace: .mirror(upper: last30(received, scale: 4.5e6), lower: last30(sent, scale: 4.5e6)))
        case .disk:
            return make("SSD", ["L 42 MB/s", "S 3,1 MB/s"], rates.map { "L \($0)" },
                        trace: .mirror(upper: last30(read, scale: 72e6), lower: last30(write, scale: 72e6)))
        case .thermal:
            return make("THERMIK", [finding ? "Hoch" : "Normal"], ["Kritisch", "Erhöht", "Normal"],
                        gauge: .thermometer(finding ? 0.75 : 0.25))
        case .battery:
            return make("AKKU", [finding ? "12 %" : "82 %"], ["100 %"],
                        gauge: .battery(finding ? 0.12 : 0.82, isCharging: !finding))
        }
    }

    static let menuBarGallerySize = CGSize(width: 880, height: 625)
    static let popoverGallerySize = CGSize(width: 1144, height: 340)

    static let menuBarSelection: [MeterKind] = [.overview, .cpu, .gpu, .memory, .network, .disk, .thermal, .battery]

    // MARK: Menüleiste

    static var menuBarGallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            PeilHead("Menüleiste: einstellbare Messanzeigen", detail: "TM17 · einfarbiges Vorlagenbild wie die Systemsymbole")
            gallerySection("Alle Elemente eingeschaltet, Standard-Darstellung") {
                MenuBarStrip(faces: menuBarSelection.map { face($0) })
            }
            gallerySection("Ohne Kurzbezeichnung") {
                MenuBarStrip(faces: menuBarSelection.map { face($0) }, showsTags: false)
            }
            gallerySection("Kompakte Auswahl: CPU als Verlauf, Arbeitsspeicher als Pegel, Netz als Verlauf") {
                MenuBarStrip(faces: [face(.cpu, style: .graph), face(.memory, style: .bar),
                                     face(.network, style: .graph)])
            }
            gallerySection("Erster Start (wie heute): nur „Auslastung“, und nur wenn sie schon an war") {
                MenuBarStrip(faces: [face(.overview)])
            }
            gallerySection("Befund-Punkt: Speicherdruck erhöht, Thermik hoch, Akku 12 % ohne Laden") {
                MenuBarStrip(faces: [face(.memory, finding: true), face(.thermal, finding: true),
                                     face(.battery, finding: true)])
            }
            gallerySection("Darstellungen je Element") { styleMatrix }
        }
        .padding(16)
        .instrumentBackground()
    }

    private static func gallerySection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(InstrumentFont.label.weight(.medium)).foregroundStyle(.instrumentSecondary)
            content()
        }
    }

    private static var styleMatrix: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text(verbatim: "")
                ForEach(GalleryMeterStyle.matrix, id: \.self) { style in
                    Text(verbatim: style.title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                }
            }
            ForEach(MeterKind.allCases.filter { $0 != .overview }, id: \.self) { kind in
                GridRow {
                    Text(verbatim: kind.title).font(InstrumentFont.body)
                    ForEach(GalleryMeterStyle.matrix, id: \.self) { style in
                        if kind.styles.contains(style) {
                            MenuBarStrip(faces: [face(kind, style: style)], showsSystemItems: false,
                                         highlighted: style == kind.defaultStyle)
                        } else {
                            Text(verbatim: "–").font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                        }
                    }
                }
            }
        }
        .instrumentPanel()
    }

    // MARK: Popover

    static var popoverGallery: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach([MeterKind.cpu, .network, .thermal], id: \.self) { kind in
                MeterPopoverSample(kind: kind)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12)))
            }
        }
        .padding(16)
        .instrumentBackground()
    }

    // MARK: Einstellungen

    static var settingsGallery: some View {
        MenuBarSettingsSample()
    }
}

/// Nachbildung der Menüleiste: Elemente links neben Grantry-Schild, WLAN, Kontrollzentrum und Uhr.
struct MenuBarStrip: View {
    let faces: [MenuBarMeterFace]
    var showsTags = true
    var showsSystemItems = true
    var highlighted = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private func face(at index: Int) -> MenuBarMeterFace {
        var face = faces[index]
        if !showsTags { face.tag = nil }
        return face
    }

    var body: some View {
        let ink = colorScheme == .dark ? Color.white : Color.black.opacity(0.88)
        HStack(spacing: 14) {
            ForEach(faces.indices, id: \.self) { index in
                Image(nsImage: MenuBarMeterRenderer.image(for: face(at: index),
                                                          increasedContrast: contrast == .increased))
                    .renderingMode(.template)
                    .foregroundStyle(ink)
            }
            if showsSystemItems {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 14))
                Image(systemName: "wifi").font(.system(size: 13))
                Image(systemName: "switch.2").font(.system(size: 13))
                Text(verbatim: "Mo. 9. Nov.  10:42").font(.system(size: 13, weight: .medium))
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.93))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(highlighted ? Color.accentColor : .clear, lineWidth: 1.5)
                }
        }
    }
}

/// Popover eines Elements mit `MeterPopoverPanel` und den Texten, die die App liefert.
private struct MeterPopoverSample: View {
    let kind: SnapshotGallery.MeterKind
    @Environment(\.self) private var environment

    var body: some View {
        switch kind {
        case .cpu:
            MeterPopoverPanel(title: "CPU", detail: "Gesamtlast, letzte 60 Sekunden", value: "38 %", hue: .cpu,
                              fraction: 0.38,
                              fields: [("Auslastung", "38 %"), ("Kerne", "10 P + 4 E"), ("Laufzeit", "3:04:17")],
                              linkTitle: "Im Task-Manager öffnen", open: {}) {
                Sparkline(series: SnapshotGallery.cpu, scale: .fixed(0...1), color: environment.instrumentColor(.cpu))
            }
        case .network:
            MeterPopoverPanel(title: "Netz", detail: "WLAN en0", value: "3,6 MB/s", hue: .received, fraction: 0.4,
                              fields: [("Empfangen", "3,6 MB/s"), ("Senden", "48 KB/s"), ("Adressen", "192.168.1.23")],
                              linkTitle: "Im Task-Manager öffnen", open: {}) {
                MirrorGraph(upper: SnapshotGallery.received, lower: SnapshotGallery.sent,
                            colors: (environment.instrumentColor(.received), environment.instrumentColor(.sent)),
                            showsGrid: false)
            }
        default:
            MeterPopoverPanel(title: "Thermik", detail: "Zustand laut macOS", value: "Normal",
                              statusItems: [StatusItem("Thermik normal", tone: .positive),
                                            StatusItem("Energiesparmodus aus", tone: .neutral)],
                              note: "macOS drosselt nicht. Bei „hoch“ oder „kritisch“ senkt macOS Takt und Leistung, "
                                  + "um den Mac zu kühlen; Grantry zeigt dann den Befund-Punkt.",
                              fields: [("Stufe", "Normal"), ("Energiesparmodus", "aus")],
                              linkTitle: "Takt und Thermik im Chip-Tab", open: {})
        }
    }
}

/// Tab „Menüleiste“ der Einstellungen (abgenommener Entwurf; der echte Tab nutzt AppKit-Steuerelemente): Vorschau, Elemente mit Schalter und Darstellung, gemeinsame Optionen.
/// Steuerelemente nachgezeichnet, weil `ImageRenderer` AppKit-Schalter und -Menüs nicht zeichnet.
private struct MenuBarSettingsSample: View {
    @Environment(\.colorScheme) private var colorScheme

    private let shown: Set<SnapshotGallery.MeterKind> = [.cpu, .memory, .network, .thermal]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Vorschau").font(.headline)
                    MenuBarStrip(faces: SnapshotGallery.menuBarSelection.filter(shown.contains)
                        .map { SnapshotGallery.face($0) })
                    Text(verbatim: "Live mit den aktuellen Messwerten. Reihenfolge: in der Menüleiste mit ⌘ ziehen – macOS merkt sie sich.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(SnapshotGallery.MeterKind.allCases, id: \.self) { kind in
                        row(kind)
                        if kind != .battery { Divider().padding(.leading, 44) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        MockSwitch(isOn: true)
                        Text(verbatim: "Kurzbezeichnung zeigen (CPU, GPU, RAM …)")
                    }
                    HStack(spacing: 10) {
                        Text(verbatim: "Takt")
                        MockSegments(items: ["0,5 s", "1 s", "2 s", "5 s"], selected: 1)
                        Text(verbatim: "gilt auch im Task-Manager").font(.callout).foregroundStyle(.secondary)
                    }
                    Text(verbatim: "Gemessen wird nur, was eingeschaltet ist; bei geschlossenem Fenster nur diese Werte.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .frame(width: 600)
        .background(colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
    }

    private var toolbar: some View {
        HStack(spacing: 24) {
            toolbarItem("gearshape", "Allgemein", selected: false)
            toolbarItem("menubar.rectangle", "Menüleiste", selected: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Text(verbatim: "Menüleiste").font(.system(size: 13, weight: .semibold)).padding(.top, -2).hidden()
        }
    }

    private func toolbarItem(_ symbol: String, _ title: String, selected: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 18))
            Text(verbatim: title).font(.system(size: 11))
        }
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.08) : .clear))
    }

    private func row(_ kind: SnapshotGallery.MeterKind) -> some View {
        let isOn = shown.contains(kind)
        return HStack(spacing: 10) {
            MockSwitch(isOn: isOn)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: kind.title)
                if let note = note(kind) {
                    Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if kind == .overview {
                Text(verbatim: "Verlauf + Pegel").foregroundStyle(.secondary)
            } else {
                MockPopup(title: kind.defaultStyle.title).opacity(isOn ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private func note(_ kind: SnapshotGallery.MeterKind) -> String? {
        switch kind {
        case .overview: "CPU-Verlauf und Speicherpegel, Popover mit vier Messkarten (bisherige Anzeige)"
        case .network: "Schnittstelle der Standardroute"
        case .disk: "Startvolume"
        case .thermal: "Zustand laut macOS, Energiesparmodus"
        case .battery: "Nur auf Macs mit Akku"
        default: nil
        }
    }
}

private struct MockSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
            .frame(width: 26, height: 15)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(radius: 0.5).padding(1.5)
            }
    }
}

private struct MockPopup: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct MockSegments: View {
    let items: [String]
    let selected: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                Text(verbatim: items[index])
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(index == selected ? Color.accentColor.opacity(0.85) : .clear))
                    .foregroundStyle(index == selected ? Color.white : .primary)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}

/// Darstellungen wie `MenuBarMeterStyle` (ManagerKit), hier ohne ManagerKit-Abhängigkeit.
enum GalleryMeterStyle: CaseIterable {
    /// Spalten der Übersicht aller Darstellungen.
    static let matrix: [GalleryMeterStyle] = [.number, .graph, .bar, .numberAndGraph, .numberAndBar]

    case number, graph, bar, numberAndGraph, numberAndBar, graphAndBar

    var title: String {
        switch self {
        case .number: "Zahl"
        case .graph: "Verlauf"
        case .bar: "Pegel"
        case .numberAndGraph: "Zahl + Verlauf"
        case .numberAndBar: "Zahl + Pegel"
        case .graphAndBar: "Verlauf + Pegel"
        }
    }

    var showsNumber: Bool { self == .number || self == .numberAndGraph || self == .numberAndBar }
    var showsGraph: Bool { self == .graph || self == .numberAndGraph || self == .graphAndBar }
    var showsBar: Bool { self == .bar || self == .numberAndBar || self == .graphAndBar }
}
