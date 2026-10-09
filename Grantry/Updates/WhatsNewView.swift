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

struct WhatsNewView: View {
    let content: ReleaseHighlights
    let model: WhatsNewModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Was ist neu?").font(.largeTitle.bold())
                Text("Grantry \(content.version)").font(.subheadline).foregroundStyle(.secondary)
                Text(verbatim: content.intro).font(.title3)
            }
            VStack(alignment: .leading, spacing: 22) {
                ForEach(content.highlights.indices, id: \.self) { index in
                    let highlight = content.highlights[index]
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: highlight.symbol)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.tint)
                            .frame(width: 42, height: 42)
                            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: highlight.title).font(.headline)
                            Text(verbatim: highlight.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Link("Alle Änderungen", destination: URL(string: "https://grantry.cstrube.de/release-notes/\(content.version).html")!)
                Spacer()
                Button("Los geht’s") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 560)
        .onAppear { model.present() }
        .onDisappear { model.dismiss() }
        .onExitCommand { close() }
    }

    private func close() {
        model.dismiss()
        dismissWindow(id: GrantryApp.whatsNewWindowID)
    }
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
