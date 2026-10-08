import ManagerKit
import SwiftUI

/// Signatur mit farbigem Symbol, bei bekanntem Team ergänzt um die Team-ID. `compact` zeigt für schmale Spalten nur die
/// Kurzform („Developer ID“, „Ad hoc“); der volle Text steht dann im Tooltip und für VoiceOver.
struct SigningLabel: View {
    enum Style {
        case full, compact
    }

    let signing: SigningInfo
    var style = Style.full

    private var fullText: String {
        signing.teamID.map { "\(signing.displayName) · Team \($0)" } ?? signing.displayName
    }

    var body: some View {
        switch style {
        case .full:
            label(fullText)
        case .compact:
            label(signing.shortName)
                .help(Text(verbatim: fullText))
                .accessibilityLabel(Text(verbatim: fullText))
        }
    }

    private func label(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: signing.tone.systemImage).foregroundStyle(signing.tone.color)
        }
    }
}
