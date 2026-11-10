import GrantryCharts
import ManagerKit
import SwiftUI

/// Kachelreihe über der Benutzertabelle (§3.6): je Benutzer ein Panel mit Peilring (Anteil an der CPU-Last) um den
/// Avatar, CPU groß, Speicher und Anteil darunter.
struct UserTiles: View {
    let presentation: UserUsagePresentation

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 480), spacing: InstrumentSpacing.panel,
                                     alignment: .leading)],
                  alignment: .leading, spacing: InstrumentSpacing.panel) {
            ForEach(presentation.rows) { row in
                UserTile(row: row, share: presentation.cpuShare(of: row), shareText: presentation.cpuShareText(of: row),
                         hue: UserBadge.hue(for: row, in: presentation))
            }
        }
    }
}

struct UserTile: View {
    /// Peilring um den Avatar.
    private static let ringSize: CGFloat = 58
    private static let avatarSize: CGFloat = 36

    let row: UserUsageRow
    let share: Double?
    let shareText: String
    let hue: InstrumentHue?

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.page) {
            ZStack {
                if let hue {
                    PeilRing(fraction: share, hue: hue)
                } else {
                    PeilRing(fraction: share, color: .instrumentSecondary)
                }
                UserAvatar(row: row, hue: hue, size: Self.avatarSize)
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: row.name).font(InstrumentFont.title).lineLimit(1)
                Text(verbatim: row.summary).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(2)
            }
            Spacer(minLength: InstrumentSpacing.group)
            VStack(alignment: .trailing, spacing: InstrumentSpacing.stack) {
                Text(verbatim: ProcessColumn.cpu.text(row.figures))
                    .font(InstrumentFont.valueLarge)
                    .foregroundStyle(hue.map(environment.instrumentTextColor) ?? .primary)
                Text(verbatim: ProcessColumn.memory.text(row.figures))
                    .font(InstrumentFont.numeric)
                    .foregroundStyle(.instrumentSecondary)
                Text(verbatim: shareText).font(InstrumentFont.micro).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
        }
        .instrumentPanel(radius: InstrumentRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("userTile")
    }
}
