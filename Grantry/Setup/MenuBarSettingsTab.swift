import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Menüleiste“ der Einstellungen (TM17, Spec 2026-11-09 § 4): Live-Vorschau der eingeschalteten Elemente mit
/// derselben Zeichnung wie in der Menüleiste, je Element Schalter und Darstellung, dazu Kurzbezeichnung und Takt.
struct MenuBarSettingsTab: View {
    let meters: MenuBarMetersModel
    @Bindable var taskManager: TaskManagerModel
    /// Vorschau live nur bei sichtbarem Fenster: SwiftUI behält das Einstellungsfenster nach dem Schließen (#482).
    @State private var isPreviewLive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            preview
            VStack(spacing: 0) {
                ForEach(MenuBarMeterKind.allCases) { kind in
                    MenuBarMeterSettingsRow(kind: kind, meters: meters)
                    if kind != MenuBarMeterKind.allCases.last { Divider() }
                }
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
            if meters.isShown(.overview) {
                MenuBarOverviewCardSettings(meters: meters)
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Kurzbezeichnung zeigen (CPU, GPU, RAM …)", isOn: Binding(
                    get: { meters.showsTags }, set: { meters.showsTags = $0 }
                ))
                .accessibilityIdentifier("menuBarMeters.showsTags")
                HStack(spacing: 10) {
                    Picker("Takt", selection: $taskManager.interval) {
                        ForEach(TaskManagerInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("menuBarMeters.interval")
                    Text("gilt auch im Task-Manager")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Gemessen wird nur, was eingeschaltet ist; bei geschlossenem Fenster nur diese Werte.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var preview: some View {
        let shown = MenuBarMeterKind.allCases.filter(meters.isShown)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Vorschau").font(.headline)
            HStack(spacing: 14) {
                if shown.isEmpty {
                    Text("Kein Element eingeschaltet.").foregroundStyle(.secondary)
                } else {
                    ForEach(shown) { kind in
                        MenuBarMeterLabel(kind: kind, meters: meters, model: taskManager, isLive: isPreviewLive)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quinary))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("menuBarMeters.preview")
            .measuresWhileVisible(hiddenDelay: .zero, start: { isPreviewLive = true }, stop: { isPreviewLive = false })
            Text("Live mit den aktuellen Messwerten. Reihenfolge: in der Menüleiste mit ⌘ ziehen – macOS merkt sie sich.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Eine Zeile: Name und Hinweis, daneben der Schalter, rechts die Darstellung. Schalter und Darstellung stehen in allen
/// Zeilen in derselben Spalte; vorher klebte der Schalter am unterschiedlich langen Namen (Nachbewertung
/// 2026.11.9/1510, Später 9).
private struct MenuBarMeterSettingsRow: View {
    /// Breite der Spalte „Darstellung“: das breiteste Menü („Zahl + Verlauf“) samt Pfeilen.
    private static let styleColumn: CGFloat = 170

    let kind: MenuBarMeterKind
    let meters: MenuBarMetersModel

    var body: some View {
        let isAvailable = meters.isAvailable(kind)
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { meters.isShown(kind) }, set: { meters.setShown($0, for: kind) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: kind.title)
                    if let note = note(isAvailable: isAvailable) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!isAvailable)
            .accessibilityIdentifier("menuBarMeter.\(kind.rawValue)")
            style.frame(width: Self.styleColumn, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var style: some View {
        if kind.styles.count > 1 {
            Picker("Darstellung", selection: Binding(get: { meters.style(for: kind) },
                                                     set: { meters.setStyle($0, for: kind) })) {
                ForEach(kind.styles) { style in
                    Text(verbatim: style.title).tag(style)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Darstellung \(kind.title)"))
            .disabled(!meters.isShown(kind))
            .accessibilityIdentifier("menuBarMeter.\(kind.rawValue).style")
        } else {
            Text(verbatim: kind.defaultStyle.title).foregroundStyle(.secondary)
        }
    }

    private func note(isAvailable: Bool) -> LocalizedStringKey? {
        if !isAvailable { return kind == .battery ? "Nur auf Macs mit Akku" : "Auf diesem Mac nicht messbar" }
        return switch kind {
        case .overview: "CPU-Verlauf und Speicherpegel, Popover mit allen wichtigen Werten"
        case .network: "Schnittstelle der Standardroute"
        case .disk: "Erstes Laufwerk"
        case .thermal: "Zustand laut macOS, Energiesparmodus"
        default: nil
        }
    }
}

/// Karten der Übersicht (#495) ein- und ausblenden; ausgeblendete Karten rechnet das Popover nicht.
private struct MenuBarOverviewCardSettings: View {
    let meters: MenuBarMetersModel

    private static let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Karten der Übersicht").font(.headline)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                ForEach(MenuBarOverviewCard.allCases) { card in
                    Toggle(isOn: Binding(get: { meters.isCardShown(card) },
                                         set: { meters.setCardShown($0, for: card) })) {
                        Text(verbatim: card.title)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("menuBarOverviewCard.\(card.rawValue)")
                }
            }
            Text("Fehlt eine Messung auf diesem Mac (etwa Akku oder GPU), fehlt auch ihre Karte.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
