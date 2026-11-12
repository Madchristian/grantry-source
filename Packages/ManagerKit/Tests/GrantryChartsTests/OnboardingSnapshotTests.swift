import SwiftUI
import Testing
@testable import GrantryCharts

/// Onboarding und „Was ist neu?“ im Lagebild (LB-5.3, #554) in hell, dunkel und „Kontrast erhöhen“: erster Start, Fehler,
/// erster Scan läuft, Ausgangsbasis gespeichert; Was ist neu mit fünf Höhepunkten.
@MainActor
@Suite struct OnboardingSnapshotTests {
    @Test(arguments: SnapshotGallery.OnboardingScene.allCases, ChartAppearance.allCases)
    func onboarding(_ scene: SnapshotGallery.OnboardingScene, _ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.onboarding(scene), named: "onboarding-\(scene.rawValue)",
                                 size: SnapshotGallery.onboardingSize, appearance: appearance)
    }

    @Test(arguments: ChartAppearance.allCases)
    func whatsNew(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(SnapshotGallery.whatsNew(), named: "neuigkeiten",
                                 size: SnapshotGallery.whatsNewSize, appearance: appearance)
    }
}

/// Was VoiceOver liest: Höhepunkt mit Titel als Beschriftung und Text als Wert (die UI-Tests suchen den Titel als
/// statischen Text), Lagezeile und laufender erster Scan mit Anteil.
@MainActor
@Suite(.serialized) struct OnboardingAccessibilityTests {
    @Test func highlightReadsTitleAndText() async throws {
        let nodes = try await AccessibilityTree.nodes(of: HighlightRow(symbol: "book.closed", title: "Wachbuch",
                                                                       text: "Ein lokaler Verlauf."))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Wachbuch",
                                                      value: "Ein lokaler Verlauf.")), "\(nodes)")
        #expect(!nodes.contains { $0.label == "Ein lokaler Verlauf." }, "\(nodes)")
    }

    @Test func windowContentKeepsPanelsAndBarReadable() async throws {
        let nodes = try await AccessibilityTree.nodes(of: WindowContent(width: 560) {
            SettingsPanel("Was ist neu?", detail: "Grantry 2026.11.11") { Text(verbatim: "Einleitung") }
        } bar: {
            WindowBar { Text(verbatim: "Hinweis") } actions: { Button("Los geht’s") {} }
        }, size: CGSize(width: 560, height: 300))
        #expect(nodes.contains { $0.label == "Was ist neu?" }, "\(nodes)")
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Los geht’s" }, "\(nodes)")
        #expect(nodes.contains { $0.role == "AXStaticText" && $0.value == "Hinweis" }, "\(nodes)")
    }
}
