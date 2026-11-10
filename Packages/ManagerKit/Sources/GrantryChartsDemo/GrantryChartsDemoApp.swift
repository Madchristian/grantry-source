import AppKit
import SwiftUI

/// Eigenständiges Prototyp-Fenster (TM-2.9, Gestaltung „Lagebild“). Läuft ohne Grantry-Bundle und berührt die installierte App nicht:
/// `swift run --package-path Packages/ManagerKit GrantryChartsDemo`.
@main
struct GrantryChartsDemoApp: App {
    init() {
        DemoSnapshots.renderIfRequested()
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Grantry – Grafik-Prototyp") {
            DemoWindow()
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { NSApplication.shared.activate() }
        }
        .defaultSize(width: 1180, height: 720)
    }
}

/// Die Graphen mit laufenden Fake-Daten auf dem Grund der Instrumententafel.
private struct DemoWindow: View {
    @State private var feed = DemoFeed()

    var body: some View {
        ScrollView { DemoGallery(feed: feed) }
            .instrumentBackground()
            .onAppear { feed.start() }
    }
}
