import GrantryCharts
import ManagerKit
import SwiftUI

// Karten der Übersicht in der Menüleiste (#495): je Karte eine eigene Ansicht mit schmalen Eingaben, damit ein Takt nur
// die Karten neu auswertet, deren Werte sich ändern. Ringe, Spuren und Verläufe aus Formen statt `Canvas` (#491); keine
// Animation je Takt.

/// Rahmen einer Karte: Titel als Überschrift, Detail, Wert rechts, darunter der Inhalt. Ein Klick springt in den
/// Task-Manager; VoiceOver bietet dafür eine eigene Aktion, die Elemente der Karte bleiben einzeln erreichbar. Die Karte
/// selbst heißt „Titel, Wert“ (ohne Wert mit `spokenValue` bzw. dem Detail), wie die Kacheln des Task-Managers.
struct OverviewCard<Content: View>: View {
    let title: String
    var detail = ""
    var value = ""
    var spokenValue: String?
    var valueColor: Color?
    let open: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.group) {
                Text(verbatim: title)
                    .font(InstrumentFont.body.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
                }
                Spacer(minLength: InstrumentSpacing.inline)
                if !value.isEmpty {
                    Text(verbatim: value)
                        .font(InstrumentFont.tileValue)
                        .foregroundStyle(valueColor ?? .primary)
                        .lineLimit(1)
                }
            }
            content
        }
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
}

/// Wert mit Legendenstrich: „▬ Benutzer 25 %“.
private struct LegendValue: View {
    let title: String
    let value: String
    let hue: InstrumentHue

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.inline) {
            LegendItem(title: title, hue: hue)
            Text(verbatim: value).font(InstrumentFont.numeric).foregroundStyle(environment.instrumentTextColor(hue))
        }
        .accessibilityElement(children: .combine)
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
            HStack(spacing: InstrumentSpacing.bar) {
                LegendValue(title: String(localized: "Benutzer"), value: cpu.userText, hue: CPUShare.user.hue)
                LegendValue(title: String(localized: "System"), value: cpu.systemText, hue: CPUShare.system.hue)
            }
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
            CoreRingBoard(groups: cores.groups.map { group in
                CoreRingBoard.Group(tag: group.label ?? tag(of: group.kind), hue: group.kind.hue,
                                    rings: group.rings.map { ring in
                                        CoreRingBoard.Ring(id: ring.id, load: ring.load,
                                                           label: ring.accessibilityLabel,
                                                           value: ring.accessibilityValue)
                                    })
            })
            HStack(spacing: InstrumentSpacing.bar) {
                ForEach(cores.averages) { average in
                    LegendValue(title: averageTitle(average), value: average.value, hue: average.kind.hue)
                }
            }
        }
    }

    private func tag(of kind: CoreKind) -> String? {
        cores.averages.first { $0.kind == kind }?.tag
    }

    /// „Leistungskerne (P)“: das Kürzel verbindet den Mittelwert mit den Gruppen darüber, auch ohne Farbe.
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
                        OverviewProcessRow(entry: entry)
                    }
                }
            }
        }
    }
}

private struct OverviewProcessRow: View {
    let entry: MenuBarOverview.ProcessEntry

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            icon
            Text(verbatim: entry.name).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: InstrumentSpacing.group)
            Text(verbatim: entry.value).font(InstrumentFont.numeric)
        }
        .frame(height: InstrumentSize.rowIcon)
        .accessibilityElement(children: .combine)
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
        }
    }
}

struct OverviewMemoryCard: View {
    let memory: MenuBarOverview.Memory
    let open: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        OverviewCard(title: String(localized: "Arbeitsspeicher"), detail: memory.detail, value: memory.value,
                     valueColor: environment.instrumentTextColor(.memory), open: open) {
            HStack(spacing: InstrumentSpacing.panel) {
                ValueRing(parts: memory.parts.map { ValueRing.Part(fraction: $0.share, hue: $0.kind.hue) },
                          value: memory.value, caption: String(localized: "belegt"))
                VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                    HStack(spacing: InstrumentSpacing.cell) {
                        ForEach(memory.parts) { part in
                            LegendItem(title: part.kind.title, hue: part.kind.hue)
                        }
                    }
                    StatusChip(String(localized: "Druck \(memory.pressureText)"), tone: pressureTone, isSmall: true)
                    Text("Swap \(memory.swap)").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                }
            }
        }
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
                     value: disk.free ?? "", open: open) {
            if let used = disk.usedShare {
                Spur(fraction: used, color: environment.instrumentColor(.diskRead),
                     label: String(localized: "Startvolume belegt"))
                    .frame(height: InstrumentSize.spurList)
            }
            if disk.driveID != nil {
                HStack(spacing: InstrumentSpacing.bar) {
                    LegendValue(title: String(localized: "Lesen"), value: disk.read, hue: .diskRead)
                    LegendValue(title: String(localized: "Schreiben"), value: disk.write, hue: .diskWrite)
                }
                if let history {
                    MirrorSparkline(upper: history.read, lower: history.write,
                                    colors: (environment.instrumentColor(.diskRead),
                                             environment.instrumentColor(.diskWrite)))
                        .frame(height: InstrumentSize.overviewMirror)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

struct OverviewNetworkCard: View {
    let network: MenuBarOverview.Network
    let history: (received: ChartSeries, sent: ChartSeries)?
    let open: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        OverviewCard(title: String(localized: "Netz"), detail: network.title,
                     spokenValue: String(localized: """
                     \(network.spokenTitle), empfangen \(network.received), gesendet \(network.sent)
                     """),
                     open: open) {
            HStack(spacing: InstrumentSpacing.bar) {
                LegendValue(title: String(localized: "↓ Empfangen"), value: network.received, hue: .received)
                LegendValue(title: String(localized: "↑ Gesendet"), value: network.sent, hue: .sent)
            }
            if let history {
                MirrorSparkline(upper: history.received, lower: history.sent,
                                colors: (environment.instrumentColor(.received), environment.instrumentColor(.sent)))
                    .frame(height: InstrumentSize.overviewMirror)
                    .accessibilityHidden(true)
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
        OverviewCard(title: String(localized: "Thermik"), detail: String(localized: "Zustand laut macOS"),
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

extension CoreKind {
    /// Farbe der Kernart (§2.3): Leistungskerne in der Farbe der CPU, Effizienzkerne Lila.
    var hue: InstrumentHue {
        switch self {
        case .performance, .unknown: .cpu
        case .efficiency: .efficiencyCores
        }
    }
}
