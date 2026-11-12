import GrantryCharts
import ManagerKit
import SwiftUI

/// Signatur mit Symbol im Zustandston, bei bekanntem Team ergänzt um die Team-ID. `compact` zeigt für schmale Spalten nur die
/// Kurzform („Developer ID“, „Ad hoc“); der volle Text steht dann im Tooltip und für VoiceOver.
struct SigningLabel: View {
    enum Style {
        case full, compact
    }

    let signing: SigningInfo
    var style = Style.full
    @Environment(\.self) private var environment

    var body: some View {
        switch style {
        case .full:
            label(signing.fullText)
        case .compact:
            label(signing.shortName)
                .help(Text(verbatim: signing.fullText))
                .accessibilityLabel(Text(verbatim: signing.fullText))
        }
    }

    private func label(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: signing.tone.systemImage).foregroundStyle(environment.statusColor(signing.tone.statusTone))
        }
    }
}

extension SigningInfo {
    /// Signatur mit Team-ID, sofern bekannt („Developer ID · Team A1B2C3D4E5“).
    var fullText: String {
        teamID.map { "\(displayName) · Team \($0)" } ?? displayName
    }
}
