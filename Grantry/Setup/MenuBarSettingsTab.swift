import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Menüleiste“ der Einstellungen (TM17, Spec 2026-11-09 § 4) im Lagebild (LB-5.2, #553): Live-Vorschau der
/// eingeschalteten Elemente mit derselben Zeichnung wie in der Menüleiste auf der Mulde, je Element Schalter und
/// Darstellung, die Karten der Übersicht als Häkchen (Mehrfachauswahl, Spec 2026-11-10 § 11.5 b), dazu Kurzbezeichnung
/// und Takt.
struct MenuBarSettingsTab: View {
    let meters: MenuBarMetersModel
    @Bindable var taskManager: TaskManagerModel

    var body: some View {
        VStack(spacing: InstrumentSpacing.panel) {
            MenuBarPreviewPanel(meters: meters, taskManager: taskManager)
            MenuBarMeterPanel(meters: meters)
            if meters.isShown(.overview) {
                MenuBarOverviewCardSettings(meters: meters)
            }
            SettingsPanel(String(localized: "Anzeige"), detail: String(localized: "Kurzbezeichnung und Takt")) {
                SettingToggle(String(localized: "Kurzbezeichnung zeigen (CPU, GPU, RAM …)"),
                              isOn: Binding(get: { meters.showsTags }, set: { meters.showsTags = $0 }),
                              identifier: "menuBarMeters.showsTags")
                SettingRow(String(localized: "Takt"), note: String(localized: "gilt auch im Task-Manager")) {
                    Picker("Takt", selection: $taskManager.interval) {
                        ForEach(TaskManagerInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("menuBarMeters.interval")
                }
                InstrumentNote(String(localized: "Gemessen wird nur, was eingeschaltet ist; bei geschlossenem Fenster nur diese Werte."))
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: SettingsLayout.width)
        .instrumentBackground()
    }
}

/// Vorschau der Menüleiste auf der Mulde (`opacity.well`, `radius.block`). Live nur bei sichtbarem Fenster: SwiftUI
/// behält das Einstellungsfenster nach dem Schließen (#482).
private struct MenuBarPreviewPanel: View {
    let meters: MenuBarMetersModel
    let taskManager: TaskManagerModel
    @State private var isPreviewLive = true

    var body: some View {
        let shown = MenuBarMeterKind.allCases.filter(meters.isShown)
        SettingsPanel(String(localized: "Vorschau"), detail: String(localized: "live mit den aktuellen Messwerten")) {
            HStack(spacing: InstrumentSpacing.page) {
                if shown.isEmpty {
                    Text("Kein Element eingeschaltet.").font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                } else {
                    ForEach(shown) { kind in
                        MenuBarMeterLabel(kind: kind, meters: meters, model: taskManager, isLive: isPreviewLive)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, InstrumentSpacing.cell)
            .padding(.vertical, InstrumentSpacing.item)
            .background(RoundedRectangle(cornerRadius: InstrumentRadius.block, style: .continuous)
                .fill(.primary.opacity(InstrumentOpacity.well)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Vorschau"))
            .accessibilityIdentifier("menuBarMeters.preview")
            .measuresWhileVisible(hiddenDelay: .zero, start: { isPreviewLive = true }, stop: { isPreviewLive = false })
            InstrumentNote(String(localized: "Reihenfolge: in der Menüleiste mit ⌘ ziehen – macOS merkt sie sich."))
        }
    }
}

/// Elemente der Menüleiste mit Schalter und Darstellung; im Kopf, wie viele eingeschaltet sind.
private struct MenuBarMeterPanel: View {
    let meters: MenuBarMetersModel

    var body: some View {
        let count = MenuBarMeterKind.allCases.count(where: meters.isShown)
        SettingsPanel(String(localized: "Elemente"),
                      detail: count == 0 ? String(localized: "keins eingeschaltet")
                          : String(localized: "\(count) von \(MenuBarMeterKind.allCases.count) eingeschaltet")) {
            ForEach(MenuBarMeterKind.allCases) { kind in
                MenuBarMeterSettingsRow(kind: kind, meters: meters)
            }
        }
    }
}

/// Eine Zeile: Name und Hinweis links, rechts Schalter und Darstellung in derselben Spalte aller Zeilen (Nachbewertung
/// 2026.11.9/1510, Später 9).
private struct MenuBarMeterSettingsRow: View {
    /// Breite der Spalte „Darstellung“: das breiteste Menü („Zahl + Verlauf“) samt Pfeilen.
    private static let styleColumn: CGFloat = 170

    let kind: MenuBarMeterKind
    let meters: MenuBarMetersModel

    var body: some View {
        let isAvailable = meters.isAvailable(kind)
        let note = note(isAvailable: isAvailable)
        SettingRow(kind.title, note: note, labelsControl: false) {
            HStack(spacing: InstrumentSpacing.cell) {
                Toggle(isOn: Binding(get: { meters.isShown(kind) }, set: { meters.setShown($0, for: kind) })) {
                    Text(verbatim: kind.title)
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!isAvailable)
                .accessibilityHint(Text(verbatim: note ?? ""))
                .accessibilityIdentifier("menuBarMeter.\(kind.rawValue)")
                style.frame(width: Self.styleColumn, alignment: .trailing)
            }
        }
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
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(Text("Darstellung \(kind.title)"))
            .disabled(!meters.isShown(kind))
            .accessibilityIdentifier("menuBarMeter.\(kind.rawValue).style")
        } else {
            Text(verbatim: kind.defaultStyle.title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
        }
    }

    private func note(isAvailable: Bool) -> String? {
        if !isAvailable {
            return kind == .battery ? String(localized: "Nur auf Macs mit Akku")
                : String(localized: "Auf diesem Mac nicht messbar")
        }
        return switch kind {
        case .overview: String(localized: "CPU-Verlauf und Speicherpegel, Popover mit allen wichtigen Werten")
        case .network: String(localized: "Schnittstelle der Standardroute")
        case .disk: String(localized: "Erstes Laufwerk")
        case .thermal: String(localized: "Zustand laut macOS, Energiesparmodus")
        default: nil
        }
    }
}

/// Karten der Übersicht (#495) ein- und ausblenden; ausgeblendete Karten rechnet das Popover nicht. Häkchen statt
/// Schalter, weil es eine Mehrfachauswahl ist (Spec 2026-11-10 § 11.5 b).
private struct MenuBarOverviewCardSettings: View {
    let meters: MenuBarMetersModel

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: InstrumentSpacing.group,
                                                           alignment: .leading), count: 3)

    var body: some View {
        SettingsPanel(String(localized: "Karten der Übersicht"), detail: String(localized: "im Popover „Übersicht“")) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: InstrumentSpacing.item) {
                ForEach(MenuBarOverviewCard.allCases) { card in
                    Toggle(isOn: Binding(get: { meters.isCardShown(card) },
                                         set: { meters.setCardShown($0, for: card) })) {
                        Text(verbatim: card.title)
                    }
                    .toggleStyle(.checkbox)
                    .font(InstrumentFont.body)
                    .accessibilityIdentifier("menuBarOverviewCard.\(card.rawValue)")
                }
            }
            InstrumentNote(String(localized: "Fehlt eine Messung auf diesem Mac (etwa Akku oder GPU), fehlt auch ihre Karte."))
        }
    }
}
