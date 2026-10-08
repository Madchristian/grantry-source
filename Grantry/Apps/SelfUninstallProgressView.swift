import ManagerKit
import SwiftUI

/// Fortschritt und Bericht von „Grantry deinstallieren …“ im Entfernen-Blatt (#143): Schritte mit Zustand als Symbol
/// und Text, Hinweis zum laufenden Schritt, danach Ergebnis mit nächsten Schritten und ggf. „Erneut versuchen“.
/// Während des Ablaufs gibt es bewusst keinen Abbrechen-Knopf – gesendete Aufträge an Finder bzw. macOS laufen weiter
/// (`SelfUninstallProgressPresentation`). VoiceOver sagt jeden begonnenen Schritt und das Ergebnis an.
struct SelfUninstallProgressView: View {
    let presentation: SelfUninstallProgressPresentation
    /// „Erneut versuchen“ ist jetzt möglich (`SelfUninstallFlow.canRetry` – nichts anderes läuft).
    let canRetry: Bool
    let retry: () -> Void
    /// „Schließen“ bzw. – liegt Grantry im Papierkorb – „Beenden“.
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: presentation.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            steps
            if let hint = presentation.runningHint { InfoLabel(text: hint) }
            if let outcome = presentation.outcome { outcomeView(outcome) }
            if !presentation.notes.isEmpty { notes }
            buttons
        }
        .interactiveDismissDisabled(presentation.isRunning)
        .onChange(of: presentation.announcement, initial: true) { _, announcement in
            if let announcement { AccessibilityNotification.Announcement(announcement).post() }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(presentation.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if let systemImage = row.systemImage {
                            Image(systemName: systemImage).foregroundStyle(row.tone.color)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 18)
                    Text(verbatim: row.title)
                        .fontWeight(row.state == .running ? .medium : .regular)
                    Spacer(minLength: 8)
                    Text(verbatim: row.statusText)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private func outcomeView(_ outcome: ActionOutcomePresentation) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: outcome.text)
                    .textSelection(.enabled)
                ForEach(outcome.details, id: \.self) { line in
                    Text(verbatim: "• " + line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        } icon: {
            Image(systemName: outcome.systemImage)
                .foregroundStyle(outcome.tone.color)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(presentation.notes, id: \.self) { note in
                Text(verbatim: note)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var buttons: some View {
        if !presentation.isRunning {
            HStack(spacing: 8) {
                if let url = presentation.outcome?.settingsURL {
                    Button("In Systemeinstellungen öffnen") { openURL(url) }
                }
                if presentation.offersLoginItemsSettings {
                    Button("Anmeldeobjekte öffnen") { LaunchAtLogin.openSettings() }
                }
                Spacer()
                // Liegt Grantry im Papierkorb, beendet „Beenden“ die App – auch neben „Erneut versuchen“, wenn ein Dienst
                // noch angemeldet ist (#143).
                Button(presentation.quitsApp ? LocalizedStringKey("Beenden") : "Schließen", role: .cancel, action: close)
                    .keyboardShortcut(presentation.offersRetry ? .cancelAction : .defaultAction)
                if presentation.offersRetry {
                    Button("Erneut versuchen", action: retry)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canRetry)
                }
            }
        }
    }
}

#if DEBUG
private struct SelfUninstallProgressPreview: View {
    let progress: SelfUninstallProgress

    var body: some View {
        SelfUninstallProgressView(
            presentation: SelfUninstallProgressPresentation(progress), canRetry: true, retry: {}, close: {}
        )
        .padding(20)
        .frame(width: 600)
    }
}

#Preview("Deinstallation, Papierkorb läuft") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.trashing)
}

#Preview("Deinstallation, Passwortabfrage abgebrochen") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.passwordCancelled)
}

#Preview("Deinstallation, Abmeldung gescheitert") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.helperFailed)
}

#Preview("Deinstallation, Grantry im Papierkorb, Dienst noch angemeldet") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.removedButHelperRegistered)
}

#Preview("Deinstallation abgeschlossen") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.removed)
}
#endif
