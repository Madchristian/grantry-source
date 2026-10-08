import AppKit
import SwiftUI

/// Sichtbarkeit des Fensters einer Ansicht: `onDisappear` feuert nicht beim Minimieren, ⌘H, Wechsel des Space,
/// vollständiger Verdeckung oder gesperrtem Bildschirm – `NSWindow.occlusionState` schon.
enum WindowVisibility {
    case visible
    /// Verdeckt, minimiert, ausgeblendet oder auf einem anderen Space.
    case hidden
    /// Das Fenster schließt bzw. die Ansicht hängt in keinem Fenster mehr.
    case closed
}

extension View {
    /// Ruft `start` auf, solange die Ansicht angezeigt wird und ihr Fenster sichtbar ist, sonst `stop`. Wird das
    /// Fenster nur verdeckt, wartet `stop` `hiddenDelay` (20 s) ab – ein kurzer Blick in Mission Control, auf einen
    /// anderen Space oder in ein anderes Fenster setzt so die Summen „seit Öffnen“ nicht zurück. Verschwindet die
    /// Ansicht oder schließt das Fenster, folgt `stop` sofort.
    func measuresWhileVisible(
        hiddenDelay: Duration = .seconds(20), start: @escaping () -> Void, stop: @escaping () -> Void
    ) -> some View {
        modifier(MeasuresWhileVisible(hiddenDelay: hiddenDelay, start: start, stop: stop))
    }
}

private struct MeasuresWhileVisible: ViewModifier {
    let hiddenDelay: Duration
    let start: () -> Void
    let stop: () -> Void
    @State private var isPresent = false
    @State private var visibility = WindowVisibility.visible
    @State private var pendingStop: Task<Void, Never>?

    private var measures: Bool { isPresent && visibility == .visible }

    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityReader { visibility = $0 })
            .onAppear { isPresent = true }
            .onDisappear {
                isPresent = false
                stopNow()
            }
            .onChange(of: measures) { _, measures in
                if measures {
                    cancelPendingStop()
                    start()
                } else if !isPresent || visibility == .closed {
                    stopNow()
                } else {
                    stopLater()
                }
            }
    }

    private func stopNow() {
        cancelPendingStop()
        stop()
    }

    private func stopLater() {
        guard pendingStop == nil else { return }
        let delay = hiddenDelay
        pendingStop = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            pendingStop = nil
            stop()
        }
    }

    private func cancelPendingStop() {
        pendingStop?.cancel()
        pendingStop = nil
    }
}

/// Meldet die Sichtbarkeit des Fensters, in dem es hängt (unsichtbarer Hintergrund).
private struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (WindowVisibility) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        WindowVisibilityView(onChange: onChange)
    }

    func updateNSView(_ view: WindowVisibilityView, context: Context) {
        view.onChange = onChange
    }
}

private final class WindowVisibilityView: NSView {
    var onChange: (WindowVisibility) -> Void
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping (WindowVisibility) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        removeObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else {
            report(.closed)
            return
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.reportOcclusion() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(.closed) }
            },
        ]
        reportOcclusion()
    }

    private func reportOcclusion() {
        guard let window else { return }
        report(window.occlusionState.contains(.visible) ? .visible : .hidden)
    }

    private func report(_ visibility: WindowVisibility) {
        // Nicht während eines SwiftUI-Updates den Zustand ändern.
        Task { [onChange] in onChange(visibility) }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
