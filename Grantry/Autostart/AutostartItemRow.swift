import ManagerKit
import SwiftUI

/// Zeile eines Autostart-Eintrags: Besitzer-App (Symbol), Label, Besitzer bzw. Programm, Status- und Prüf-Badges.
/// Tragen mehrere Plists dasselbe Label (`sharesService`, #138), nennt die Zeile zusätzlich die Datei.
struct AutostartItemRow: View {
    let item: AutostartItem
    let badges: [RecordBadge]
    var sharesService = false

    var body: some View {
        HStack(spacing: 10) {
            AutostartItemIcon(item: item, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.owner?.displayName ?? item.program {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if sharesService, let plistPath = item.plistPath {
                    Text(verbatim: URL(fileURLWithPath: plistPath).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 4) {
                    AutostartStatusRow(statuses: item.statusBadges)
                    RecordBadgesRow(badges: badges)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Symbol der Besitzer-App; ohne Besitzer ein SF Symbol für die Art des Eintrags.
struct AutostartItemIcon: View {
    let item: AutostartItem
    var size: CGFloat = 24

    var body: some View {
        if let owner = item.owner {
            AppIconView(app: owner, size: size)
        } else {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: size * 0.7))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

extension AutostartKind {
    /// SF Symbol der Eintragsart.
    var systemImage: String {
        switch self {
        case .loginItem: "person.crop.circle.badge.checkmark"
        case .launchAgent: "gearshape"
        case .launchDaemon: "gearshape.2"
        case .backgroundTask: "square.stack.3d.down.right"
        }
    }
}
