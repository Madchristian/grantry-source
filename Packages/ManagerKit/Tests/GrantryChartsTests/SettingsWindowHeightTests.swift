import AppKit
import Observation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Einstellungsfenster auf kleinem Bildschirm (#525): ein Fenster wie die Settings-Szene (Fenster richtet sich nach dem
/// Inhalt, Tabs, „Allgemein“ 1262 pt hoch) mit eingespeistem sichtbarem Bereich. Es bleibt in jedem Bereich, nach dem
/// Wiederherstellen eines zu großen Rahmens und nach dem Wechsel der Auflösung ganz auf dem Bildschirm; der Rest rollt.
@MainActor
@Suite(.serialized) struct SettingsWindowHeightTests {
    /// MacBook Pro 14 in Standardauflösung mit Dock (gemessen 10.11.2026) und eine kleinere Auflösung.
    private static let standard = CGRect(x: 0, y: 65, width: 1512, height: 884)
    private static let small = CGRect(x: 0, y: 40, width: 1280, height: 560)

    @Observable final class Screen {
        var visibleFrame: CGRect
        var tab = 0
        init(_ visibleFrame: CGRect) { self.visibleFrame = visibleFrame }
    }

    private struct SettingsLike: View {
        let screen: Screen

        var body: some View {
            @Bindable var screen = screen
            TabView(selection: $screen.tab) {
                Tab("Allgemein", systemImage: "gearshape", value: 0) { ScreenCappedScroll { Self.block(1262) } }
                Tab("Menüleiste", systemImage: "menubar.rectangle", value: 1) { ScreenCappedScroll { Self.block(300) } }
            }
            .environment(\.visibleScreenFrame) { [screen] _ in screen.visibleFrame }
        }

        private static func block(_ height: CGFloat) -> some View {
            Color.gray.frame(width: 560, height: height)
        }
    }

    /// Wie SwiftUI die Settings-Szene anlegt: Inhalt bestimmt Größe, kleinste und größte Größe des Fensters.
    private static func open(on screen: Screen, tab: Int = 0) async throws -> NSWindow {
        screen.tab = tab
        let controller = NSHostingController(rootView: SettingsLike(screen: screen))
        controller.sizingOptions = [.preferredContentSize, .minSize, .maxSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        let visible = screen.visibleFrame
        window.setFrameTopLeftPoint(CGPoint(x: visible.midX - 280, y: visible.maxY))
        window.orderBack(nil)
        try await settle()
        return window
    }

    private static func settle() async throws {
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(30)) }
    }

    private static func expectOnScreen(_ window: NSWindow, _ screen: Screen, sourceLocation: SourceLocation = #_sourceLocation) {
        let frame = window.frame, visible = screen.visibleFrame
        #expect(frame.height <= visible.height, "Fenster \(frame) höher als sichtbar \(visible)", sourceLocation: sourceLocation)
        #expect(frame.minY >= visible.minY, "Unterkante \(frame) unter dem Bildschirm \(visible)", sourceLocation: sourceLocation)
        #expect(frame.maxY <= visible.maxY, "Titel- und Bereichsleiste \(frame) über dem Bildschirm \(visible)",
                sourceLocation: sourceLocation)
    }

    @Test func opensWithinASmallScreen() async throws {
        let screen = Screen(Self.small)
        let window = try await Self.open(on: screen)
        defer { window.close() }
        Self.expectOnScreen(window, screen)
        // Der Bereich rollt, statt das Fenster klein zu halten: Es nutzt die Höhe bis auf den Rand.
        #expect(window.frame.height >= screen.visibleFrame.height - 2 * ScreenFit.margin - 1)
    }

    @Test func switchingToTheTallTabStaysOnScreen() async throws {
        let screen = Screen(Self.small)
        let window = try await Self.open(on: screen, tab: 1)
        defer { window.close() }
        screen.tab = 0
        try await Self.settle()
        Self.expectOnScreen(window, screen)
    }

    /// Kleinere Auflösung bei offenem Fenster: Die Grenze folgt dem Bildschirm, nicht dem Stand beim Öffnen.
    @Test func shrinksWhenTheResolutionChanges() async throws {
        let screen = Screen(Self.standard)
        let window = try await Self.open(on: screen)
        defer { window.close() }
        screen.visibleFrame = Self.small
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await Self.settle()
        Self.expectOnScreen(window, screen)
    }

    /// Gespeicherter Rahmen aus 2026.11.8 (1446): 560 × 1262 an y −313 auf 1512 × 949.
    @Test func restoredTooTallFrameIsCorrected() async throws {
        let screen = Screen(Self.standard)
        let window = try await Self.open(on: screen)
        defer { window.close() }
        window.setFrame(CGRect(x: 476, y: -313, width: 560, height: 1262), display: false)
        try await Self.settle()
        Self.expectOnScreen(window, screen)
    }
}
