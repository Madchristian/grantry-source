import AppKit
import SwiftUI

/// Rahmen eines Fensters, das ganz auf dem sichtbaren Bildschirm liegt: so wenig wie möglich verschoben, die Größe
/// bleibt. Ist das Fenster größer als der Bildschirm, bleibt die Titelleiste sichtbar (oben bündig).
public enum ScreenFit {
    /// Abstand eines Fensters, das sich nach seinem Inhalt richtet, zum oberen und unteren Rand des sichtbaren Bereichs.
    public static let margin: CGFloat = 8

    public static func frame(_ frame: CGRect, fittingIn visible: CGRect) -> CGRect {
        var fitted = frame
        if fitted.maxX > visible.maxX { fitted.origin.x = visible.maxX - fitted.width }
        if fitted.minX < visible.minX { fitted.origin.x = visible.minX }
        if fitted.minY < visible.minY { fitted.origin.y = visible.minY }
        if fitted.maxY > visible.maxY { fitted.origin.y = visible.maxY - fitted.height }
        return fitted
    }

    /// Höchste Höhe eines Inhalts, dessen Fenster `chrome` höher ist als er selbst (Titel- und Bereichsleiste), damit
    /// das Fenster mit Rand in den sichtbaren Bereich passt.
    public static func contentLimit(in visible: CGRect, chrome: CGFloat) -> CGFloat {
        max(0, visible.height - 2 * margin - chrome)
    }
}

extension EnvironmentValues {
    /// Sichtbarer Bereich des Bildschirms eines Fensters, nur in Tests gesetzt.
    @Entry var visibleScreenFrame: (@MainActor (NSWindow) -> CGRect?)?
}

/// Hält das Fenster nach jeder Größenänderung auf dem sichtbaren Bildschirm (#486) und meldet, wie hoch die Ansicht, in
/// deren Hintergrund es liegt, darin höchstens sein darf (#525). Die Einstellungen wachsen beim Wechsel des Tabs nach
/// unten; geöffnet auf „Menüleiste“ ragte „Allgemein“ danach 30 pt über den unteren Bildschirmrand (Nachbewertung
/// 2026.11.9/1510, Sollte 3).
struct WindowOnScreenKeeper: NSViewRepresentable {
    let onContentLimit: (CGFloat) -> Void
    @Environment(\.visibleScreenFrame) private var visibleFrame

    func makeNSView(context: Context) -> WindowOnScreenView { WindowOnScreenView() }

    func updateNSView(_ view: WindowOnScreenView, context: Context) {
        view.visibleFrame = visibleFrame ?? WindowOnScreenView.screenVisibleFrame
        view.onContentLimit = onContentLimit
    }
}

/// Beobachtet Größe und Bildschirm seines Fensters und schiebt es zurück auf den sichtbaren Bildschirm. Mit
/// `onContentLimit` meldet es außerdem die höchste Höhe der Ansicht, in deren Hintergrund es liegt: aus dem Bildschirm
/// des Fensters und dem gemessenen Rahmen darum, neu beim Öffnen, bei jeder Größenänderung, beim Wechsel des Bildschirms
/// und beim Wechsel der Auflösung. Intern für die Tests.
final class WindowOnScreenView: NSView {
    static let screenVisibleFrame: (NSWindow) -> CGRect? = { $0.screen?.visibleFrame ?? NSScreen.main?.visibleFrame }

    var visibleFrame: (NSWindow) -> CGRect? = WindowOnScreenView.screenVisibleFrame
    var onContentLimit: ((CGFloat) -> Void)?
    private var observers: [NSObjectProtocol] = []

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let changes: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResizeNotification, window), (NSWindow.didChangeScreenNotification, window),
            (NSApplication.didChangeScreenParametersNotification, nil),
        ]
        observers = changes.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            }
        }
        // Beim Einhängen sind Fenster und Ansicht noch nicht ausgelegt.
        RunLoop.main.perform { [weak self] in MainActor.assumeIsolated { self?.fit() } }
    }

    func fit() {
        guard let window, let visible = visibleFrame(window) else { return }
        if let onContentLimit, bounds.height > 0 {
            onContentLimit(ScreenFit.contentLimit(in: visible, chrome: window.frame.height - bounds.height))
        }
        let fitted = ScreenFit.frame(window.frame, fittingIn: visible)
        if fitted.origin != window.frame.origin { window.setFrameOrigin(fitted.origin) }
    }
}
