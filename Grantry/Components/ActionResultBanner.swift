import GrantryCharts
import ManagerKit
import SwiftUI

/// Meldung zum Ergebnis einer Aktion als Banner im Lagebild (`InstrumentBanner`): Ergebnis als Titel, Einzelzeilen als
/// Satz darunter, bei unbestätigter Wirkung mit Deeplink in die Systemeinstellungen. VoiceOver sagt das Ergebnis an,
/// sobald es erscheint.
struct ActionResultBanner: View {
    let result: ActionOutcomePresentation
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Die Zahl der Zeilen begrenzt das Kit (`ActionOutcomePresentation.maximumDetails`).
        InstrumentBanner(result.text, message: result.details.map { "• " + $0 }.joined(separator: "\n"),
                         tone: result.tone.statusTone) {
            if let url = result.settingsURL {
                Button("In Systemeinstellungen öffnen") { openURL(url) }
            }
            BannerDismissButton(action: dismiss)
        }
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
                    .padding([.horizontal, .top], InstrumentSpacing.panel)
            }
            // Inhalt füllt den Rest, damit die Meldung oben bleibt – auch wenn er selbst klein ist
            // (z. B. „Keine Auswahl“) und der Stapel sonst mittig im Bereich stünde.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
