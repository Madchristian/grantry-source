import ManagerKit
import SwiftUI

/// Eine App in der Liste: Symbol, Name und Größe, „Version · Herkunft · Architektur“, zuletzt benutzt und Badges.
/// VoiceOver liest den Satz aus dem Kit (`InstalledAppRow.accessibilityLabel`), dazu Badges außer „prüfen“ (der
/// Schweregrad steht schon im Satz).
struct InstalledAppRowView: View {
    let row: InstalledAppRow
    let badges: [RecordBadge]
    /// Größe und Nutzung sind noch nicht geladen.
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(app: row.app.identity, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: row.app.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: row.sizeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: isLoading ? String(localized: "Nutzung wird ermittelt …") : row.lastUsedText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    RecordBadgesRow(badges: badges)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
        .accessibilityValue(Text(verbatim: badges.filter { !$0.isReview }.map(\.accessibilityLabel).joined(separator: ", ")))
    }
}

private extension RecordBadge {
    var isReview: Bool {
        if case .review = self { true } else { false }
    }
}
