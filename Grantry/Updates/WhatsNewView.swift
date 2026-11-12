import GrantryCharts
import ManagerKit
import SwiftUI

/// Redaktionell gepflegte Inhalte des Releases; nur passend zur tatsächlich laufenden Version zeigen.
struct ReleaseHighlights: Decodable {
    struct Highlight: Decodable {
        let symbol: String
        let title: String
        let body: String
    }

    let version: String
    let intro: String
    let highlights: [Highlight]

    static let current: ReleaseHighlights? = {
        guard let url = Bundle.main.url(forResource: "ReleaseHighlights", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let content = try? JSONDecoder().decode(ReleaseHighlights.self, from: data),
              content.version == InstalledBuild.current().version, !content.highlights.isEmpty else { return nil }
        return content
    }()
}

/// Fenster „Was ist neu?“ im Lagebild (LB-5.3, #554; Entwurf LB-5.1, Spec 2026-11-10 § 11.5 h): Panel mit Peilkopf ohne
/// Ring und Version, Einleitung, Höhepunkte als Zeilen mit Symbol im Kreis; unten die Aktionsleiste mit dem Link auf alle
/// Änderungen und „Los geht’s“.
struct WhatsNewView: View {
    let content: ReleaseHighlights
    let model: WhatsNewModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        WindowContent(width: WhatsNewLayout.width) {
            SettingsPanel(String(localized: "Was ist neu?"), detail: String(localized: "Grantry \(content.version)")) {
                Text(verbatim: content.intro)
                    .font(InstrumentFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    ForEach(content.highlights, id: \.title) { highlight in
                        HighlightRow(symbol: highlight.symbol, title: highlight.title, text: highlight.body)
                    }
                }
            }
        } bar: {
            WindowBar {
                Link("Alle Änderungen", destination: URL(string: "https://grantry.cstrube.de/release-notes/\(content.version).html")!)
                    .font(InstrumentFont.body)
            } actions: {
                Button("Los geht’s") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { model.present() }
        .onDisappear { model.dismiss() }
        .onExitCommand { close() }
    }

    private func close() {
        model.dismiss()
        dismissWindow(id: GrantryApp.whatsNewWindowID)
    }
}

/// Maße des Fensters „Was ist neu?“: Breite wie bisher (Entwurf LB-5.1).
enum WhatsNewLayout {
    static let width: CGFloat = 560
}

struct WhatsNewCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Was ist neu?") { openWindow(id: GrantryApp.whatsNewWindowID) }
                .disabled(ReleaseHighlights.current == nil)
        }
    }
}
