import SwiftUI

/// Kennzahlen „Titel Wert“ in einer Zeile, zu schmal untereinander – wie in den Panels des Chip-Tabs (`FactRow`), für
/// Kacheln des Übersichts-Baukastens (Takt, Leerlauf, Spitze …). Jede Kennzahl ist ein VoiceOver-Element.
public struct FactLine: View {
    let facts: [PanelFact]

    public init(_ facts: [PanelFact]) {
        self.facts = facts
    }

    public var body: some View {
        FactRow(facts: facts)
    }
}
