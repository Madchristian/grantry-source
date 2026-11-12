import SwiftUI

/// Glied eines aufgeklappten Kopfs (`DisclosureSection`, Spec 2026-11-10 § 11.4 g; LB-4.4, #550), etwa ein Prozess
/// eines Agenten-Baums: Name links, rechts der Wert in Sekundärfarbe mit gleich breiten Ziffern; nur Anzeige.
/// VoiceOver liest den Namen als Beschriftung, den Wert als Wert.
public struct DisclosureMemberRow: View {
    let title: String
    let value: String

    public init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            Text(verbatim: title).font(InstrumentFont.label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: InstrumentSpacing.group)
            Text(verbatim: value).font(InstrumentFont.label.monospacedDigit()).foregroundStyle(.instrumentSecondary)
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .accessibilityReading(Text(verbatim: title), value: Text(verbatim: Self.spokenValue(value)))
    }

    /// Wert für VoiceOver: wie angezeigt („PID 48211 · 512 MB“).
    nonisolated static func spokenValue(_ value: String) -> String { value }
}
