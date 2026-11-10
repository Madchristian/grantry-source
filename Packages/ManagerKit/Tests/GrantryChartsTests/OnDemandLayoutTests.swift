import AppKit
import SwiftUI
import Testing
@testable import GrantryCharts

/// Bausteine für Inhalte, die erst geladen werden oder höher als der Bildschirm sein können (#479, Bewertung
/// 2026.11.9/1492, Mängel 3 und 5): `LoadingSlot` startet seine Ladung auch ohne vorgeladenen Wert, `HeightCappedScroll`
/// bleibt höchstens so hoch wie erlaubt.
@MainActor
@Suite struct OnDemandLayoutTests {
    /// Zählt Ladungen; die Ansicht im Fenster schreibt hinein.
    @MainActor final class LoadProbe {
        var loads = 0
    }

    /// Hält den geladenen Wert wie `MacProfileSection`: am Anfang nil, die Ladung setzt ihn.
    private struct LoadingHost: View {
        let probe: LoadProbe
        @State private var value: String?

        var body: some View {
            LoadingSlot(value) { value in
                Text(verbatim: value)
            } placeholder: {
                ProgressView()
            } load: {
                probe.loads += 1
                value = "geladen"
            }
        }
    }

    /// Ohne vorgeladenen Wert läuft die Ladung beim Erscheinen, eingebettet wie der Steckbrief im Bereich „Sicherheit“
    /// (Bildlauf, Stapel, Spalte fester Breite). Bis 2026.11.9 (1492) hing sie dort an einer leeren `Group { if let … }`
    /// und startete nie; der Steckbrief „Dieser Mac“ blieb aus.
    @Test func loadRunsWithoutPreloadedValue() async throws {
        let probe = LoadProbe()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView {
            VStack {
                Text(verbatim: "Lagezeile")
                HStack(alignment: .top) {
                    LoadingHost(probe: probe).frame(width: 120)
                    Color.gray.frame(height: 40)
                }
            }
        })
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<50 where probe.loads == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(probe.loads == 1)
    }

    private static func block(height: CGFloat) -> some View {
        Color.clear.frame(width: 300, height: height)
    }

    private static func fittingHeight(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true)).fittingSize.height
    }

    /// Höherer Inhalt als erlaubt: Die Fläche bleibt bei der Grenze, der Rest scrollt. Bis 2026.11.9 (1492) öffneten die
    /// Einstellungen „Allgemein“ 1231 pt hoch auf einem 949 pt hohen Bildschirm.
    @Test func tallContentStopsAtLimit() {
        #expect(Self.fittingHeight(HeightCappedScroll(limit: 400) { Self.block(height: 1200) }) == 400)
    }

    /// Niedriger Inhalt: Die Fläche ist so hoch wie der Inhalt, ohne Leerraum darunter.
    @Test func shortContentKeepsItsHeight() {
        #expect(Self.fittingHeight(HeightCappedScroll(limit: 400) { Self.block(height: 250) }) == 250)
    }
}
