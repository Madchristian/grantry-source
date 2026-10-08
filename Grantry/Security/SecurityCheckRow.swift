import ManagerKit
import SwiftUI

/// Eine Prüfung: Symbol und Statustext (nicht nur Farbe), Klartext, Erklärung, Details und Angebote (Aktionen bzw.
/// Links). Texte und VoiceOver-Label stammen aus `SecurityCheckPresentation`.
struct SecurityCheckRow: View {
    let check: SecurityCheckPresentation
    let actions: ActionRunner
    let helperState: HelperState?
    /// Hervorhebung nach einem Klick auf eine Benachrichtigung bzw. einen Verlaufseintrag.
    let isFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: check.systemImage)
                    .foregroundStyle(check.tone.color)
                    .accessibilityHidden(true)
                Text(verbatim: check.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(verbatim: check.statusText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(check.tone.color)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: check.accessibilityLabel))
            Text(verbatim: check.summary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)  // im Label der Kopfzeile enthalten
            if let explanation = check.explanation {
                Text(verbatim: explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(check.details, id: \.self) { line in
                Text(verbatim: line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !check.offers.isEmpty {
                offers
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(isFocused ? Color.accentColor.opacity(0.12) : nil)
        .accessibilityElement(children: .contain)
    }

    private var offers: some View {
        HStack(spacing: 8) {
            ForEach(check.offers, id: \.self) { offer in
                switch offer {
                case .action(let action, let title):
                    Button(title) { Task { await actions.perform(action) } }
                        .disabled(!actions.canStart || !SecurityOverview.isAvailable(action, helperState: helperState))
                case .link(let title, let url):
                    Button(title) { openURL(url) }
                        .buttonStyle(.link)
                }
            }
            if actions.runningRecordID == check.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Aktion läuft")
            }
        }
        .padding(.top, 2)
    }
}
