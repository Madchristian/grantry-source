import GrantryCharts
import ManagerKit
import SwiftUI

/// Kennzahlen als Messfelder in gleich breiten Spalten (§3.6): bis sechs in einer Reihe, mehr auf zwei gleich lange
/// Reihen verteilt, nie ein einzelnes Feld allein (Bewertung 2026.11.7, Mangel 11). Gemeinsam für „Leistung“ und
/// „Energie“.
struct StatGrid: View {
    let stats: [PerformanceStat]

    var body: some View {
        MeasureFieldRow(fields: stats.map { (title: $0.title, value: $0.value) })
    }
}
