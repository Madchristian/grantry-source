import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachel „Datenträger“ des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): Startvolume und erstes
/// Laufwerk. 1 × 1 freier Platz (ohne Volume Lesen und Schreiben), 2 × 1 Belegung und Raten, 2 × 2 wie die Karte aus
/// PR 623 mit Belegung, frei von gesamt, Lesen und Schreiben als Tabelle und dem Verlauf der letzten Minute, 4 × 1 Verlauf
/// mit Raten rechts und der Belegung im Kopf.
struct OverviewDiskTile: OverviewTile {
    static let kind = OverviewTileKind.disk

    let value: OverviewRateReading<MenuBarOverview.Disk>
    let span: OverviewTileSpan
    let open: () -> Void

    @Environment(\.self) private var environment

    static func value(from source: OverviewTileSource) -> OverviewRateReading<MenuBarOverview.Disk>? {
        source.overview.disk.map { disk in
            OverviewRateReading(base: disk, history: disk.driveID.flatMap {
                OverviewRateHistory(source.history, upper: .diskRead($0), lower: .diskWrite($0))
            })
        }
    }

    var body: some View {
        let disk = value.base
        // In 1 × 1 passt „Datenträger“ nicht neben den Rand; „Volume“ sagt dort dasselbe.
        OverviewCard(title: span == .small ? String(localized: "Volume") : Self.kind.title,
                     detail: [.banner, .large].contains(span) ? String(localized: "Startvolume") : "",
                     value: header, spokenValue: disk.spokenValue, open: open) {
            switch span {
            case .small:
                if let free = disk.freeAmount {
                    OverviewFigure(value: free, detail: String(localized: "frei"))
                } else {
                    rates(compact: true)
                }
            case .wide:
                used
                if disk.driveID != nil { rates(compact: false) }
            case .large:
                used
                if let free = disk.free {
                    Text(verbatim: free).font(InstrumentFont.label.monospacedDigit()).lineLimit(1)
                }
                if disk.driveID != nil {
                    LegendPair(first: (String(localized: "Lesen"), disk.read, .diskRead),
                               second: (String(localized: "Schreiben"), disk.write, .diskWrite))
                    sparkline
                }
            default:
                HStack(alignment: .bottom, spacing: InstrumentSpacing.panel) {
                    sparkline
                    if disk.driveID != nil {
                        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) { rates(compact: false) }
                    }
                }
            }
        }
    }

    /// Kopfwert: 1 × 1 und 2 × 2 zeigen den freien Platz im Inhalt, 2 × 1 kurz, 4 × 1 mit Größe des Volumes.
    private var header: String {
        switch span {
        case .small, .large: ""
        case .banner, .panel: value.base.free ?? ""
        default: value.base.freeAmount.map { String(localized: "\($0) frei") } ?? ""
        }
    }

    @ViewBuilder private var used: some View {
        if let used = value.base.usedShare {
            Spur(fraction: used, color: environment.instrumentColor(.diskRead),
                 label: String(localized: "Startvolume belegt"))
                .frame(height: InstrumentSize.spurList)
        }
    }

    @ViewBuilder private var sparkline: some View {
        if let history = value.history {
            OverviewRateSparkline(history: history, hues: (.diskRead, .diskWrite))
        }
    }

    /// Lesen und Schreiben; in 1 × 1 untereinander mit Kürzel, sonst mit Legendenstrich.
    @ViewBuilder private func rates(compact: Bool) -> some View {
        let disk = value.base
        if compact {
            OverviewRateLine(symbol: String(localized: "L"), value: disk.read, hue: .diskRead)
            OverviewRateLine(symbol: String(localized: "S"), value: disk.write, hue: .diskWrite)
        } else if span == .banner {
            LegendValue(title: String(localized: "Lesen"), value: disk.read, hue: .diskRead).fixedSize()
            LegendValue(title: String(localized: "Schreiben"), value: disk.write, hue: .diskWrite).fixedSize()
        } else {
            HStack(spacing: InstrumentSpacing.bar) {
                LegendValue(title: String(localized: "L"), value: disk.read, hue: .diskRead)
                LegendValue(title: String(localized: "S"), value: disk.write, hue: .diskWrite)
            }
        }
    }
}
