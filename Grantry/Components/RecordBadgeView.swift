import ManagerKit
import SwiftUI

/// Kleine farbige Kapsel mit Kurzbeschriftung und optionalem Symbol (Badges in Listen und Detailansichten).
struct BadgeCapsule: View {
    let title: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(verbatim: title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(0.15), in: .capsule)
    }
}

/// Kapsel für ein `RecordBadge` („neu“, „prüfen“, „aufräumen“); „prüfen“ zeigt den Schweregrad auch als Symbol und
/// nennt ihn VoiceOver.
struct RecordBadgeView: View {
    let badge: RecordBadge

    var body: some View {
        BadgeCapsule(title: badge.title, color: badge.color, systemImage: badge.systemImage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: badge.accessibilityLabel))
    }
}

/// Die Badges eines Eintrags nebeneinander; leer, wenn keine vorliegen.
struct RecordBadgesRow: View {
    let badges: [RecordBadge]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(badges, id: \.self, content: RecordBadgeView.init)
        }
    }
}

/// Status-Badges eines Autostart-Eintrags (aktiv/deaktiviert, geladen/nicht geladen).
struct AutostartStatusRow: View {
    let statuses: [AutostartStatus]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(statuses, id: \.self) { status in
                BadgeCapsule(title: status.title, color: status.tone.color)
            }
        }
    }
}
