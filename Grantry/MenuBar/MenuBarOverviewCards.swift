import GrantryCharts
import ManagerKit
import SwiftUI

// Karten der Übersicht in der Menüleiste (#495): je Karte eine eigene Ansicht mit schmalen Eingaben, damit ein Takt nur
// die Karten neu auswertet, deren Werte sich ändern. Ringe, Spuren und Verläufe aus Formen statt `Canvas` (#491); keine
// Animation je Takt.

extension EnvironmentValues {
    /// Karte in einer Zeile mit einer zweiten: Sie füllt die Höhe der Zeile, damit beide gleich hoch enden.
    @Entry var overviewCardFillsRow = false
}

/// Rahmen einer Karte: Titel als Überschrift, Detail, Wert rechts, darunter der Inhalt. Die Legende (`accessory`) steht
/// in der Kopfzeile, solange sie dort Platz hat, sonst darunter; passt auch das Detail nicht neben Titel und Wert
/// (schmale Karte, langer Name), rückt es in eine eigene Zeile, statt abzuschneiden. Ein Klick springt in den
/// Task-Manager; VoiceOver bietet dafür eine eigene Aktion, die Elemente der Karte bleiben einzeln erreichbar. Die Karte
/// selbst heißt „Titel, Wert“ (ohne Wert mit `spokenValue` bzw. dem Detail), wie die Kacheln des Task-Managers.
struct OverviewCard<Accessory: View, Content: View>: View {
    let title: String
    let detail: String
    let value: String
    let spokenValue: String?
    let valueColor: Color?
    let open: () -> Void
    let accessory: Accessory
    let content: Content

    @Environment(\.overviewCardFillsRow) private var fillsRow

    init(title: String, detail: String = "", value: String = "", spokenValue: String? = nil, valueColor: Color? = nil,
         open: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.value = value
        self.spokenValue = spokenValue
        self.valueColor = valueColor
        self.open = open
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            ViewThatFits(in: .horizontal) {
                headline(showsDetail: true) { accessory }
                VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                    headline(showsDetail: true) { EmptyView() }
                    accessory
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                    VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                        headline(showsDetail: false) { EmptyView() }
                        if !detail.isEmpty { detailText.truncationMode(.middle) }
                    }
                    accessory
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: fillsRow ? .infinity : nil, alignment: .topLeading)
        .instrumentPanel(padding: InstrumentSpacing.cell, radius: InstrumentRadius.card)
        .contentShape(RoundedRectangle(cornerRadius: InstrumentRadius.card, style: .continuous))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: [title, spokenValue ?? (value.isEmpty ? detail : value)]
            .filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: Text("Im Task-Manager öffnen"), open)
        .accessibilityIdentifier("popoverCard")
        .help("Im Task-Manager anzeigen")
    }

    private func headline(showsDetail: Bool, @ViewBuilder legend: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.group) {
            Text(verbatim: title)
                .font(InstrumentFont.body.weight(.semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if showsDetail, !detail.isEmpty { detailText }
            legend()
            Spacer(minLength: InstrumentSpacing.inline)
            if !value.isEmpty {
                Text(verbatim: value)
                    .font(InstrumentFont.tileValue)
                    .foregroundStyle(valueColor ?? .primary)
                    .lineLimit(1)
            }
        }
    }

    private var detailText: some View {
        Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
    }
}

extension OverviewCard where Accessory == EmptyView {
    /// Karte ohne Legende in der Kopfzeile.
    init(title: String, detail: String = "", value: String = "", spokenValue: String? = nil, valueColor: Color? = nil,
         open: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, detail: detail, value: value, spokenValue: spokenValue, valueColor: valueColor,
                  open: open, accessory: { EmptyView() }, content: content)
    }
}

/// Wert mit Legendenstrich: „▬ Benutzer 25 %“; mit `isSpread` als Tabellenzeile, Wert am rechten Rand.
private struct LegendValue: View {
    let title: String
    let value: String
    let hue: InstrumentHue
    var isSpread = false

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.inline) {
            LegendItem(title: title, hue: hue).lineLimit(1)
            if isSpread { Spacer(minLength: 0) }
            Text(verbatim: value).font(InstrumentFont.numeric).foregroundStyle(environment.instrumentTextColor(hue))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Zwei Legendenwerte: nebeneinander, solange die Karte breit genug ist, sonst untereinander als Tabelle.
private struct LegendPair: View {
    let first: (title: String, value: String, hue: InstrumentHue)
    let second: (title: String, value: String, hue: InstrumentHue)

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: InstrumentSpacing.bar) { values(isSpread: false) }
            VStack(spacing: InstrumentSpacing.inline) { values(isSpread: true) }
        }
    }

    @ViewBuilder
    private func values(isSpread: Bool) -> some View {
        LegendValue(title: first.title, value: first.value, hue: first.hue, isSpread: isSpread)
        LegendValue(title: second.title, value: second.value, hue: second.hue, isSpread: isSpread)
    }
}

/// Angabe ohne Farbe als Tabellenzeile: Bezeichnung links, Wert am rechten Rand.
private struct FactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: InstrumentSpacing.inline) {
            Text(verbatim: title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            Spacer(minLength: 0)
            Text(verbatim: value).font(InstrumentFont.numeric).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Gespiegelter Verlauf einer Karte (Lesen/Schreiben, Empfangen/Senden). In einer Zeile mit einer zweiten Karte füllt
/// er die übrige Höhe, damit unter dem Verlauf der niedrigeren Karte keine leere Fläche bleibt.
private struct OverviewMirror: View {
    let upper: ChartSeries
    let lower: ChartSeries
    let hues: (upper: InstrumentHue, lower: InstrumentHue)

    @Environment(\.self) private var environment
    @Environment(\.overviewCardFillsRow) private var fillsRow

    var body: some View {
        MirrorSparkline(upper: upper, lower: lower,
                        colors: (environment.instrumentColor(hues.upper), environment.instrumentColor(hues.lower)))
            .frame(minHeight: InstrumentSize.overviewMirror,
                   maxHeight: fillsRow ? .infinity : InstrumentSize.overviewMirror)
            .accessibilityHidden(true)
    }
}

// MARK: - CPU und Kerne

struct OverviewCPUCard: View {
    let cpu: MenuBarOverview.CPU
    /// Gesamtlast und Systemanteil der letzten Minute; `nil` bei geschlossenem Popover.
    let history: (total: ChartSeries, system: ChartSeries)?
    let open: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        OverviewCard(title: String(localized: "CPU"), detail: cpu.clock ?? "", value: cpu.value,
                     valueColor: environment.instrumentTextColor(.cpu), open: open) {
            HStack(spacing: InstrumentSpacing.cell) {
                LegendValue(title: String(localized: "Benutzer"), value: cpu.userText, hue: CPUShare.user.hue)
                LegendValue(title: String(localized: "System"), value: cpu.systemText, hue: CPUShare.system.hue)
            }
        } content: {
            Group {
                if let history {
                    StackedSparkline(lower: history.system, total: history.total,
                                     colors: (lower: CPUShare.system.hue, upper: CPUShare.user.hue))
                } else {
                    Color.clear
                }
            }
            .frame(height: InstrumentSize.cardGraph)
            .accessibilityHidden(true)
        }
    }
}

/// Teile der CPU-Last im gestapelten Verlauf: Benutzer in der Farbe der CPU, System abgesetzt in Rosé (§2.3,
/// zusammengesetzte Größe mit Legende); nicht Lila, das in der Karte darunter die Effizienzkerne zeigt.
enum CPUShare {
    case user, system

    var hue: InstrumentHue {
        switch self {
        case .user: .cpu
        case .system: .neuralEngine
        }
    }
}

struct OverviewCoresCard: View {
    let cores: MenuBarOverview.Cores
    let open: () -> Void

    var body: some View {
        OverviewCard(title: String(localized: "Kerne"),
                     spokenValue: cores.averages.map { "\($0.title) \($0.value)" }.joined(separator: ", "),
                     open: open) {
            // Drei Kernklassen (Super-, Leistungs-, Effizienzkerne, #589) passen nicht in eine Zeile der Karte:
            // dann untereinander statt abgeschnitten, die Breite bleibt.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: InstrumentSpacing.cell) { averages }
                VStack(alignment: .leading, spacing: InstrumentSpacing.inline) { averages }
            }
        } content: {
            CoreRingBoard(groups: cores.groups.map { group in
                CoreRingBoard.Group(tag: group.label ?? tag(of: group.kind), hue: group.kind.hue,
                                    rings: group.rings.map { ring in
                                        CoreRingBoard.Ring(id: ring.id, load: ring.load,
                                                           label: ring.accessibilityLabel,
                                                           value: ring.accessibilityValue)
                                    })
            })
        }
    }

    private var averages: some View {
        ForEach(cores.averages) { average in
            LegendValue(title: averageTitle(average), value: average.value, hue: average.kind.hue)
        }
    }

    private func tag(of kind: CoreKind) -> String? {
        cores.averages.first { $0.kind == kind }?.tag
    }

    /// „Super-Kerne (S)“, „Leistungskerne (P)“: das Kürzel verbindet den Mittelwert mit den Gruppen darüber, auch ohne Farbe.
    private func averageTitle(_ average: MenuBarOverview.CoreAverage) -> String {
        average.tag.map { "\(average.title) (\($0))" } ?? average.title
    }
}

// MARK: - Prozesse

struct OverviewProcessesCard: View {
    let processes: MenuBarOverview.Processes
    let open: () -> Void

    var body: some View {
        OverviewCard(title: String(localized: "Prozesse"), detail: String(localized: "höchste CPU-Last"), open: open) {
            if processes.entries.isEmpty {
                Text("Die erste Messung folgt mit dem nächsten Takt.")
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
            } else {
                VStack(spacing: InstrumentSpacing.stack) {
                    ForEach(processes.entries) { entry in
                        OverviewProcessRow(entry: entry, widestMemory: processes.widestMemory,
                                           widestValue: processes.widestValue)
                    }
                }
            }
        }
    }
}

/// Zeile eines Prozesses: Symbol, Name, Lastbalken im Vergleich der gezeigten Einträge, Arbeitsspeicher und CPU-Last.
/// Die Zahlenspalten sind in jeder Zeile so breit wie ihr längster Wert (`widest…`), damit die Balken bündig stehen.
private struct OverviewProcessRow: View {
    let entry: MenuBarOverview.ProcessEntry
    let widestMemory: String
    let widestValue: String

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            icon
            Text(verbatim: entry.name).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spur(fraction: entry.loadFraction, color: environment.instrumentColor(.cpu))
                .frame(width: InstrumentSize.overviewLoadBar, height: InstrumentSize.spurHeader)
            column(entry.memory, widest: widestMemory).foregroundStyle(.instrumentSecondary)
            column(entry.value, widest: widestValue)
        }
        .frame(height: InstrumentSize.rowIcon)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(entry.name), CPU \(entry.value), Arbeitsspeicher \(entry.memory)"))
    }

    /// Rechtsbündiger Wert in der Breite des längsten Werts der Spalte.
    private func column(_ value: String, widest: String) -> some View {
        Text(verbatim: widest).font(InstrumentFont.numeric).lineLimit(1).hidden()
            .overlay(alignment: .trailing) {
                Text(verbatim: value).font(InstrumentFont.numeric).lineLimit(1).fixedSize()
            }
    }

    @ViewBuilder
    private var icon: some View {
        if let app = entry.app {
            AppIconView(app: AppIdentity(bundleID: app.bundleID, path: app.bundlePath, displayName: app.name,
                                         signing: .unknown, presence: .present),
                        size: InstrumentSize.rowIcon)
        } else {
            Image(systemName: entry.isSystem ? "lock.shield.fill" : "gearshape.fill")
                .font(InstrumentFont.rowIcon)
                .foregroundStyle(.instrumentSecondary)
                .frame(width: InstrumentSize.rowIcon, height: InstrumentSize.rowIcon)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - GPU und Arbeitsspeicher

struct OverviewGPUCard: View {
    let gpu: MenuBarOverview.GPU
    let open: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        OverviewCard(title: String(localized: "GPU"), detail: gpu.clock ?? "", value: gpu.value,
                     valueColor: environment.instrumentTextColor(.gpu), open: open) {
            HStack(spacing: InstrumentSpacing.panel) {
                ForEach(gpu.rings) { ring in
                    ValueRing(parts: [ValueRing.Part(fraction: ring.fraction, hue: .gpu)], value: ring.value,
                              caption: ring.caption)
                }
            }
            if let memory = gpu.memory {
                FactRow(title: String(localized: "Speicher"), value: memory)
            }
        }
    }
}

struct OverviewMemoryCard: View {
    let memory: MenuBarOverview.Memory
    let open: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        OverviewCard(title: String(localized: "Arbeitsspeicher"), value: memory.value,
                     valueColor: environment.instrumentTextColor(.memory), open: open) {
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                ValueRing(parts: memory.parts.map { ValueRing.Part(fraction: $0.share, hue: $0.kind.hue) },
                          value: memory.value, caption: String(localized: "belegt"))
                VStack(spacing: InstrumentSpacing.inline) {
                    ForEach(memory.parts) { part in
                        LegendValue(title: part.kind.title, value: part.value, hue: part.kind.hue, isSpread: true)
                    }
                    // Bündig mit den Bezeichnungen der Legende darüber, ohne deren Strich: Swap ist kein Teil des Rings.
                    FactRow(title: String(localized: "Swap"), value: memory.swap)
                        .padding(.leading, InstrumentSize.legendStroke.width + InstrumentSpacing.inline)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: InstrumentSpacing.group) {
                    pressure
                    Spacer(minLength: 0)
                    usage
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                    pressure
                    usage
                }
            }
        }
    }

    private var pressure: some View {
        StatusChip(String(localized: "Druck \(memory.pressureText)"), tone: pressureTone, isSmall: true)
    }

    /// „17,75 GB von 48 GB“.
    private var usage: some View {
        Text(verbatim: memory.detail).font(InstrumentFont.label.monospacedDigit())
            .foregroundStyle(.instrumentSecondary).lineLimit(1)
    }

    private var pressureTone: StatusTone {
        switch memory.pressure {
        case .normal?: .positive
        case .warning?: .finding
        case .critical?: .critical
        case nil: .neutral
        }
    }
}

// MARK: - Datenträger und Netz

struct OverviewDiskCard: View {
    let disk: MenuBarOverview.Disk
    /// Lesen und Schreiben der letzten Minute; `nil` bei geschlossenem Popover oder ohne Laufwerk.
    let history: (read: ChartSeries, write: ChartSeries)?
    let open: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        OverviewCard(title: String(localized: "Datenträger"), detail: String(localized: "Startvolume"),
                     spokenValue: disk.free, open: open) {
            if let used = disk.usedShare {
                Spur(fraction: used, color: environment.instrumentColor(.diskRead),
                     label: String(localized: "Startvolume belegt"))
                    .frame(height: InstrumentSize.spurList)
            }
            if let free = disk.free {
                Text(verbatim: free).font(InstrumentFont.label.monospacedDigit()).lineLimit(1)
            }
            if disk.driveID != nil {
                LegendPair(first: (String(localized: "Lesen"), disk.read, .diskRead),
                           second: (String(localized: "Schreiben"), disk.write, .diskWrite))
                if let history {
                    OverviewMirror(upper: history.read, lower: history.write, hues: (.diskRead, .diskWrite))
                }
            }
        }
    }
}

struct OverviewNetworkCard: View {
    let network: MenuBarOverview.Network
    let history: (received: ChartSeries, sent: ChartSeries)?
    let open: () -> Void

    var body: some View {
        OverviewCard(title: String(localized: "Netz"), detail: network.title,
                     spokenValue: String(localized: """
                     \(network.spokenTitle), empfangen \(network.received), gesendet \(network.sent)
                     """),
                     open: open) {
            LegendPair(first: (String(localized: "↓ Empfangen"), network.received, .received),
                       second: (String(localized: "↑ Gesendet"), network.sent, .sent))
            if let history {
                OverviewMirror(upper: history.received, lower: history.sent, hues: (.received, .sent))
            }
        }
    }
}

// MARK: - Thermik, Akku, Last und Laufzeit

struct OverviewThermalCard: View {
    let thermal: MenuBarOverview.Thermal
    let open: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        let tone = thermal.tone.statusTone
        OverviewCard(title: String(localized: "Thermik"), detail: String(localized: "laut macOS"),
                     value: thermal.value, valueColor: environment.statusTextColor(tone), open: open) {
            HStack(spacing: InstrumentSpacing.cell) {
                Spur(fraction: thermal.level, color: environment.statusColor(tone))
                    .frame(height: InstrumentSize.spurList)
                    .accessibilityHidden(true)
                Text(verbatim: thermal.lowPowerMode).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .fixedSize()
            }
        }
    }
}

struct OverviewBatteryCard: View {
    let battery: MenuBarOverview.Battery
    let open: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        OverviewCard(title: String(localized: "Akku"), detail: battery.state, value: battery.value,
                     valueColor: environment.instrumentTextColor(.battery), open: open) {
            Spur(fraction: battery.charge, color: environment.instrumentColor(.battery))
                .frame(height: InstrumentSize.spurList)
                .accessibilityHidden(true)
        }
    }
}

/// Durchschnittslast und Laufzeit als eine Zeile unter den Karten.
struct OverviewSummaryRow: View {
    let summary: MenuBarOverview.Summary

    var body: some View {
        HStack(spacing: InstrumentSpacing.bar) {
            if let load = summary.loadAverage {
                fact(String(localized: "Durchschnittslast"), load)
            }
            Spacer(minLength: 0)
            if let uptime = summary.uptime {
                fact(String(localized: "Laufzeit"), uptime)
            }
        }
        .padding(.horizontal, InstrumentSpacing.cell)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(spacing: InstrumentSpacing.inline) {
            Text(verbatim: title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            Text(verbatim: value).font(InstrumentFont.numeric)
        }
        .accessibilityElement(children: .combine)
    }
}

