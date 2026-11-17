import SwiftUI

/// Klickbedienung der Diagramm-Bausteine aus Formen (`ArcFan` seit #633, `RingRadar` seit #640): je Element eine
/// unsichtbare Klickfläche über Punkt und Beschriftung, mit Tastatur erreichbar; für VoiceOver je Element ein Knopf mit
/// Name, Wert, Hinweis und Zustand „ausgewählt“. Gewählte Elemente tragen ihre Beschriftung weiß auf dem
/// Grantry-Verlauf wie ein gewähltes Segment, also nicht nur über Farbe. Was ein Klick bewirkt, entscheidet der
/// Aufrufer; der Rückruf bekommt die Kennungen, für die das Element steht – beim Sammel-Element alle zusammengefassten.
enum ChartPick {
    /// Innenabstand der Kapsel um eine gewählte Beschriftung.
    static let captionPadding = InstrumentSpacing.inline

    /// Ob ein Element als gewählt gilt: sobald eine der Kennungen, für die es steht, gewählt ist.
    nonisolated static func isPicked(_ members: [String], picked: Set<String>) -> Bool {
        !picked.isDisjoint(with: members)
    }

    /// Beschriftung eines gewählten Elements: weiß auf dem Verlauf in einer Kapsel, die auch ohne Farbe erkennbar ist.
    static func pickedCaption(_ caption: Text) -> some View {
        caption.foregroundStyle(.white)
            .padding(.horizontal, captionPadding)
            .padding(.vertical, InstrumentSpacing.stack)
            .background(Capsule().fill(GrantryBrand.fill))
    }

    /// Klickfläche eines Elements in den Koordinaten der Zeichenfläche.
    struct Target: Identifiable {
        let id: String
        /// Beschriftung für den Tooltip.
        let caption: String
        /// Kennungen, für die das Element steht.
        let members: [String]
        let frame: CGRect
    }

    /// Eintrag der VoiceOver-Liste: jedes Element einzeln, auch die im Bild zusammengefassten.
    struct Spoken {
        let id: String
        let label: String
        let value: String
        /// Eigener Text ohne Klickbedienung; `nil` liest „Name, Wert“.
        var text: String?

        /// Eintrag ohne Klickbedienung.
        var plainText: String { text ?? "\(label), \(value)" }
    }

    /// Unsichtbare Klickflächen über der Zeichnung; VoiceOver liest statt ihrer die Liste (`SpokenList`).
    struct Areas: View {
        let targets: [Target]
        let hint: String?
        let onPick: (Set<String>) -> Void

        var body: some View {
            ForEach(targets) { target in
                Button { onPick(Set(target.members)) } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: target.frame.width, height: target.frame.height)
                .position(x: target.frame.midX, y: target.frame.midY)
                .help(hint.map { "\(target.caption): \($0)" } ?? target.caption)
            }
        }
    }

    /// Elemente als Liste für VoiceOver: mit `onPick` je Element ein Knopf mit Name, Wert, Hinweis und Zustand
    /// „ausgewählt“, sonst je Element ein Text.
    struct SpokenList: View {
        let title: String
        let items: [Spoken]
        let picked: Set<String>
        let hint: String?
        let onPick: ((Set<String>) -> Void)?

        var body: some View {
            VStack {
                ForEach(items, id: \.id) { item in
                    if let onPick {
                        Button { onPick([item.id]) } label: { Text(verbatim: item.label) }
                            // ax-value: Knopf, behält seine Rolle und damit den Wert
                            .accessibilityValue(Text(verbatim: item.value))
                            .accessibilityHint(Text(verbatim: hint ?? ""))
                            .accessibilityAddTraits(picked.contains(item.id) ? .isSelected : [])
                    } else {
                        Text(verbatim: item.plainText)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: title))
        }
    }
}
