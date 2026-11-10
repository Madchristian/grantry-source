import SwiftUI
@testable import GrantryCharts

/// Linke Spalte des Energie-Tabs (TM-14.4, #397) mit den Texten aus `EnergyPresentation`: beim Laden für den
/// Vorschau-Stand `EnergyPreviewData.frameCharging` (100-W-Netzteil, gut 31 W Ladeleistung), dazu die Sonderzustände
/// (TM-14.6, #399) Akkubetrieb mit kritischem Ladestand ohne Panel „Netzteil und Laden“ und Ladeschutz am Netzteil. Im
/// Kopf des Panels steht, was das Netzteil liefert (Leistungsaufnahme und Ladeleistung, Befund 10.11.2026).
@MainActor
extension SnapshotGallery {
    static var energyCharging: some View {
        energyColumn(EnergyColumn(
            charge: 0.47, caption: "Lädt",
            fields: [("Leistungsaufnahme", "24 W"), ("Akku", "+31 W"), ("Voll in", "1:12 h"),
                     ("Ladezyklen", "86 von 1.000"), ("Maximale Kapazität", "98 %"), ("Zustand", "Normal")],
            charging: EnergyColumn.Charging(value: "55 W", fraction: 0.55,
                                            fields: [("Netzteil", "100 W"), ("Ladeleistung", "31 W"),
                                                     ("Ladezustand", "Lädt"), ("Auslastung", "55 %")], note: nil)))
    }

    static var energyOnBattery: some View {
        energyColumn(EnergyColumn(
            charge: 0.18, caption: "Akkubetrieb",
            fields: [("Leistungsaufnahme", "14 W"), ("Akku", "−14 W"), ("Restlaufzeit", "0:52 h"),
                     ("Ladezyklen", "86 von 1.000"), ("Maximale Kapazität", "98 %"), ("Zustand", "Normal")],
            charging: nil))
    }

    static var energyChargeLimit: some View {
        energyColumn(EnergyColumn(
            charge: 0.8, caption: "Netzteil",
            fields: [("Leistungsaufnahme", "9,6 W"), ("Akku", "−4,3 W"), ("Ladezyklen", "86 von 1.000"),
                     ("Maximale Kapazität", "98 %"), ("Zustand", "Normal")],
            charging: EnergyColumn.Charging(value: "5,3 W", fraction: 0.053,
                                            fields: [("Netzteil", "100 W"), ("Ladeleistung", "0 W"),
                                                     ("Ladezustand", "Lädt nicht"), ("Auslastung", "5 %")],
                                            note: "Der Mac läuft vom Netzteil. macOS lädt den Akku gerade nicht, "
                                                + "etwa wegen Ladegrenze, optimiertem Laden oder Wärme.")))
    }

    private static func energyColumn(_ column: EnergyColumn) -> some View {
        column
            .frame(width: InstrumentSize.columnWide)
            .padding(10)
            .instrumentBackground()
    }
}

/// Akku-Panel wie `BatteryCard` (bis 20 % kritisch) und, falls am Netzteil gemeldet, „Netzteil und Laden“ wie
/// `ChargingCard`.
private struct EnergyColumn: View {
    struct Charging {
        let value: String
        let fraction: Double
        let fields: [(String, String)]
        let note: String?
    }

    let charge: Double
    let caption: String
    let fields: [(String, String)]
    let charging: Charging?
    @Environment(\.self) private var environment

    var body: some View {
        let percent = "\(Int((charge * 100).rounded())) %"
        let tone: StatusTone = charge <= 0.2 ? .critical : .positive
        VStack(spacing: InstrumentSpacing.panel) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                PeilHead("Akku", value: percent, hue: .battery, fraction: charge)
                ArcGauge(fraction: charge, color: environment.statusColor(tone),
                         textColor: tone == .critical ? environment.statusTextColor(tone) : .primary, value: percent,
                         caption: caption)
                    .frame(height: InstrumentSize.arcGauge)
                    .frame(maxWidth: .infinity)
                MeasureFieldRow(fields: fields)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
            if let charging {
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    PeilHead("Netzteil und Laden", detail: "pd charger", value: charging.value, hue: .power,
                             fraction: charging.fraction)
                    MeasureFieldRow(fields: charging.fields)
                    if let note = charging.note {
                        Text(verbatim: note)
                            .font(InstrumentFont.label)
                            .foregroundStyle(.instrumentSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .instrumentPanel()
            }
        }
    }
}
