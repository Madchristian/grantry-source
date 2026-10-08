import ManagerKit
import SwiftUI

/// Eine Änderung aus dem Verlauf: Symbol der Änderungsart, Titel und Text via `ChangeDescription`, ungelesene fett,
/// Zeitpunkt relativ (frischt sich einmal pro Minute auf).
struct ChangeRow: View {
    let event: HistoryEvent

    var body: some View {
        let description = ChangeDescription(event.event)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.event.kind.systemImage)
                .foregroundStyle(event.event.kind.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(description.title)
                        .fontWeight(event.isRead ? .regular : .semibold)
                    Spacer(minLength: 8)
                    TimelineView(.everyMinute) { context in
                        Text(RelativeTime.text(for: event.event.detectedAt, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(description.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension ChangeEvent.Kind {
    /// SF Symbol der Änderungsart.
    var systemImage: String {
        switch self {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .removed: "minus.circle.fill"
        }
    }

    var tone: PresentationTone {
        switch self {
        case .added: .positive
        case .modified: .warning
        case .removed: .neutral
        }
    }
}

/// Relative Zeitangaben („vor 5 Minuten“) in der Sprache der Bundle-Lokalisierung (`de`).
enum RelativeTime {
    /// `now` stammt oft aus einem Minutentakt und kann vor `date` liegen – dann „jetzt“ statt „in … s“.
    static func text(for date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: max(now, date))
    }
}
