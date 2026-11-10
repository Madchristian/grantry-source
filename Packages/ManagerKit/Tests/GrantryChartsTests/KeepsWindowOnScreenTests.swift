import AppKit
import Testing
@testable import GrantryCharts

/// Einstellungen beim Tabwechsel (#486, Nachbewertung 2026.11.9/1510, Sollte 3): Geöffnet auf „Menüleiste“ (637 pt hoch,
/// Oberkante bei 837 von 982) wuchs das Fenster auf „Allgemein“ (867 pt) nach unten über den Bildschirmrand.
@MainActor
@Suite struct KeepsWindowOnScreenTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func frameBelowTheScreenMovesUpWithoutResizing() {
        let fitted = ScreenFit.frame(CGRect(x: 476, y: -30, width: 560, height: 867), fittingIn: Self.screen)
        #expect(fitted == CGRect(x: 476, y: 0, width: 560, height: 867))
    }

    @Test func frameOnTheScreenStaysPut() {
        let frame = CGRect(x: 476, y: 200, width: 560, height: 637)
        #expect(ScreenFit.frame(frame, fittingIn: Self.screen) == frame)
    }

    @Test func tallerThanTheScreenKeepsTheTitleBarVisible() {
        let fitted = ScreenFit.frame(CGRect(x: 0, y: -100, width: 560, height: 1100), fittingIn: Self.screen)
        #expect(fitted.maxY == Self.screen.maxY)
    }

    @Test func growingWindowIsMovedBackOnScreen() async throws {
        let window = NSWindow(contentRect: CGRect(x: 476, y: 200, width: 560, height: 637),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let keeper = WindowOnScreenView()
        keeper.visibleFrame = { _ in Self.screen }
        window.contentView?.addSubview(keeper)
        // Wie der Tabwechsel: größer, Oberkante bleibt – die Unterkante läge 30 pt unter dem Bildschirm.
        let top = window.frame.maxY
        window.setFrame(CGRect(x: 476, y: top - 897, width: 560, height: 897), display: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.frame.minY == 0)
        #expect(window.frame.height == 897)
        window.close()
    }
}
