import GrantryCharts
import ManagerKit
import SwiftUI

/// Maße der Tabellen „Prozesse“, „Energie“, „Benutzer“ und „App-Verlauf“, gemeinsam für Kopf und Zeilen.
enum ProcessTableLayout {
    static let valueColumns: [ProcessColumn] = [.cpu, .memory, .disk, .network]
    static let valueWidth: CGFloat = 108
    /// Schmalste Wertspalte: Summe im Kopf („34,72 GB“) noch ungekürzt.
    static let valueMinimum: CGFloat = 88
    /// Schmalster Name samt Pfeil und Symbol; darunter stünde der Name senkrecht (Nachbewertung 2026.11.9/1510).
    static let nameMinimum: CGFloat = 150
    static let spacing = InstrumentSpacing.inline
    static let childIndent: CGFloat = 22
    static let iconSize = InstrumentSize.rowIcon
    /// Einzug des Namens im Kopf: Pfeil, Abstand und Symbol der Zeilen.
    static let nameIndent = InstrumentSize.disclosure + InstrumentSpacing.group + iconSize
    /// Waagrechter Innenrand von Kopf (`bar`) und Zeilen (`group` um Zeilen und Zeile) einer Tabelle.
    static let horizontalInset = 2 * InstrumentSpacing.bar

    /// Name und `count` Wertspalten, davor wahlweise weitere Spalten (`leading`, etwa „Prozesse“ der Benutzer).
    static func columns(values count: Int, after leading: [InstrumentColumns.Column] = []) -> InstrumentColumns {
        InstrumentColumns([.name(minimum: nameMinimum)] + leading
                          + Array(repeating: .fixed(valueWidth, minimum: valueMinimum), count: count),
                          spacing: spacing)
    }
}
