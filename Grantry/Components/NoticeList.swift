import ManagerKit
import SwiftUI

/// Hinweise mit Warnsymbol, z. B. über einer Liste. Ohne `fixedSize(vertical:)` (d342e9b): Lange Hinweise werden nach
/// drei Zeilen gekürzt, der Tooltip zeigt sie ganz.
struct NoticeList: View {
    let notices: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notices, id: \.self) { notice in
                Label {
                    Text(verbatim: notice).lineLimit(3).help(Text(verbatim: notice))
                } icon: {
                    Image(systemName: PresentationTone.warning.systemImage)
                        .foregroundStyle(PresentationTone.warning.color)
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hinweis mit Info-Symbol (ohne Warnfarbe).
struct InfoLabel: View {
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }
}
