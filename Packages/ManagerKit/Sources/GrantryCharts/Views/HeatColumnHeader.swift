import SwiftUI

/// Spaltenkopf der Tabellen (§3.7): Summe der Spalte in runden Ziffern, darunter Titel mit Sortierpfeil und eine Spur in
/// der Farbe der Messgröße der Spalte – wie die Zellen darunter. Wert und Spur wechseln ohne Animation: Die Summen ändern
/// sich mit jedem Takt, ein Übergang liefe also ständig (Leistungsbudget).
public struct HeatColumnHeader: View {
    let title: String
    let value: String
    let heat: Double?
    /// `nil`: nicht nach dieser Spalte sortiert.
    let sortAscending: Bool?
    let alignment: HorizontalAlignment
    let hue: InstrumentHue

    @Environment(\.self) private var environment

    public init(title: String, value: String, heat: Double?, sortAscending: Bool?,
                alignment: HorizontalAlignment = .trailing, hue: InstrumentHue = .cpu) {
        self.title = title
        self.value = value
        self.heat = heat.map { min(max($0, 0), 1) }
        self.sortAscending = sortAscending
        self.alignment = alignment
        self.hue = hue
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: InstrumentSpacing.stack + 1) {
            if !value.isEmpty {
                Text(verbatim: value)
                    .font(InstrumentFont.value)
                    .lineLimit(1)
            }
            HStack(spacing: InstrumentSpacing.stack + 1) {
                Text(verbatim: title)
                if let sortAscending {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(InstrumentFont.micro.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
            .font(InstrumentFont.label.weight(sortAscending == nil ? .regular : .semibold))
            .foregroundStyle(sortAscending == nil ? .instrumentSecondary : .primary)
            Spur(fraction: heat, color: environment.instrumentColor(hue))
                .frame(height: InstrumentSize.spurHeader)
                .accessibilityHidden(true)
                .opacity(heat == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .bottom))
        .accessibilityReading(Text(verbatim: title), value: Text(verbatim: value))
        .accessibilityAddTraits(sortAscending == nil ? [] : .isSelected)
    }
}
