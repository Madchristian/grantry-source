import SwiftUI

// Gerüst der Liste-Detail-Bereiche Berechtigungen, Autostart, Agenten und Apps im Lagebild (LB-2.2, #539; Entwurf
// LB-2.1, #538, Spec 2026-11-10 §4.3): oben die Zustandszeile, darunter Umschalter, Abdeckung und Hinweise des Bereichs,
// darunter Auswahlliste und Detail im `InstrumentSplit`. Liste und Detail kommen als Slots, damit dieselbe Hülle auch
// die Leerzustände zeigt.

/// Inhalt der Zustandszeile eines Bereichs (Spec §11.2 a): Urteil, Chips und rechts Anzahl und Scanzeit.
public struct InventoryHead: Hashable, Sendable {
    public let verdict: String
    public let shield: ShieldForm
    public let items: [StatusItem]
    public let facts: String

    /// Schild mit Befund-Punkt.
    public var finding: Bool { shield == .finding }

    public init(verdict: String, shield: ShieldForm, items: [StatusItem], facts: String) {
        self.verdict = verdict
        self.shield = shield
        self.items = items
        self.facts = facts
    }

    public init(verdict: String, finding: Bool, items: [StatusItem], facts: String) {
        self.init(verdict: verdict, shield: ShieldForm(finding: finding), items: items, facts: facts)
    }
}

/// Bereich im Lagebild: Zustandszeile, Bedienelemente des Bereichs, Liste und Detail. Füllt die Fläche, die das Fenster
/// gibt; der Grund kommt von `instrumentBackground()`.
public struct InventoryBoard<Controls: View, ListContent: View, DetailContent: View>: View {
    let head: InventoryHead
    let controls: Controls
    let list: ListContent
    let detail: DetailContent

    public init(head: InventoryHead, @ViewBuilder controls: () -> Controls, @ViewBuilder list: () -> ListContent,
                @ViewBuilder detail: () -> DetailContent) {
        self.head = head
        self.controls = controls()
        self.list = list()
        self.detail = detail()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: head.verdict, shield: head.shield, items: head.items, facts: head.facts)
            controls
            InstrumentSplit { list } detail: { detail }
        }
        .padding(InstrumentSpacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentBackground()
    }
}
