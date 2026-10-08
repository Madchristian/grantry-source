import ManagerKit
import SwiftUI

/// Inline-Meldung zum Ergebnis einer Aktion; bei unbestätigter Wirkung mit Deeplink in die Systemeinstellungen.
/// VoiceOver sagt das Ergebnis an, sobald es erscheint.
struct ActionResultBanner: View {
    let result: ActionOutcomePresentation
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: result.systemImage)
                .foregroundStyle(result.tone.color)
                .accessibilityHidden(true)
            // Bewusst ohne `fixedSize(vertical:)`: Damit meldete der Text bei der Mindestgrößen-Abfrage des Fensters
            // (Breite 0) über 1000 pt Höhe, das Fenster wurde zu klein für seinen Inhalt und Sidebar und Liste
            // rutschten unter die Titelleiste. Umbrechen tut der Text auch so.
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: result.text)
                    .textSelection(.enabled)
                // Die Zahl der Zeilen begrenzt das Kit (`ActionOutcomePresentation.maximumDetails`).
                ForEach(result.details, id: \.self) { line in
                    Text(verbatim: "• " + line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let url = result.settingsURL {
                Button("In Systemeinstellungen öffnen") { openURL(url) }
            }
            Button("Meldung schließen", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Meldung schließen")
        }
        .padding(10)
        .background(result.tone.color.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(result.tone.color.opacity(0.3)) }
        .accessibilityElement(children: .contain)
        .onChange(of: result, initial: true) { _, result in
            AccessibilityNotification.Announcement(result.text).post()
        }
    }
}

/// Inhalt mit der Meldung zur letzten Aktion in `context` darüber – unabhängig davon, welcher Eintrag gezeigt wird.
struct ActionResultContainer<Content: View>: View {
    let actions: ActionRunner
    let context: ActionContext
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if let result = actions.result(in: context) {
                ActionResultBanner(result: result, dismiss: actions.dismissResult)
                    .padding([.horizontal, .top], 12)
            }
            // Inhalt füllt den Rest, damit die Meldung oben bleibt – auch wenn er selbst klein ist
            // (z. B. „Keine Auswahl“) und der Stapel sonst mittig im Bereich stünde.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
