import SwiftUI

/// Aktiver Zusatzfilter als Chip neben Suche und Umschaltern, etwa „Ziel: Deutschland“ aus dem Bogenfächer (#633): weiß
/// auf dem Grantry-Verlauf wie ein gewähltes Segment, mit Kreuz. Der ganze Chip ist ein Knopf, der den Filter aufhebt –
/// mit Tastatur erreichbar; VoiceOver liest die Art als Beschriftung, die Auswahl als Wert und das Aufheben als Hinweis.
public struct InstrumentFilterChip: View {
    let label: String
    let value: String
    let removeHint: String
    let remove: () -> Void

    /// - Parameters:
    ///   - label: Art des Filters, etwa „Ziel“.
    ///   - value: Auswahl, etwa „Deutschland“.
    ///   - removeHint: Was ein Klick bewirkt, als Tooltip und VoiceOver-Hinweis.
    public init(_ label: String, value: String, removeHint: String, remove: @escaping () -> Void) {
        self.label = label
        self.value = value
        self.removeHint = removeHint
        self.remove = remove
    }

    public var body: some View {
        Button(action: remove) {
            HStack(spacing: InstrumentSpacing.inline) {
                Text(verbatim: "\(label): \(value)")
                    .font(InstrumentFont.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "xmark.circle.fill")
                    .font(InstrumentFont.label)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, InstrumentSpacing.group)
            .padding(.vertical, InstrumentSpacing.inline)
            .background(Capsule().fill(GrantryBrand.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(removeHint)
        .accessibilityLabel(Text(verbatim: label))
        // ax-value: Knopf, behält seine Rolle und damit den Wert
        .accessibilityValue(Text(verbatim: value))
        .accessibilityHint(Text(verbatim: removeHint))
    }
}
