import Foundation

/// Ob gerade ein Fenster oder Popover Livewerte misst (#662): Jede Ansicht mit `measuresWhileVisible` meldet Beginn und
/// Ende ihrer Messung unter einer eigenen Kennung. Sichtbar ist, solange mindestens eine misst; Fenster, Popover und
/// Vorschau zählen gleich. Beobachter erfahren nur den Wechsel – kein Zeitgeber, keine Abfrage je Takt. Die App reicht
/// den Stand an `MonitoringEngine.setLiveViewsVisible(_:)` weiter, damit die verteilte Komplettprüfung aufschiebt.
@MainActor
public final class LiveViewPresence {
    /// Gemeinsamer Stand aller Ansichten der App.
    public static let shared = LiveViewPresence()

    private var measuring: Set<UUID> = []
    private var observer: ((Bool) -> Void)?

    public init() {}

    public var isVisible: Bool { !measuring.isEmpty }

    /// Meldet, ob die Ansicht `id` misst; wiederholte Meldungen desselben Stands ändern nichts.
    public func setMeasuring(_ isMeasuring: Bool, for id: UUID) {
        let wasVisible = isVisible
        if isMeasuring { measuring.insert(id) } else { measuring.remove(id) }
        if isVisible != wasVisible { observer?(isVisible) }
    }

    /// `report` erhält sofort den aktuellen Stand und danach jeden Wechsel; ersetzt einen früheren Beobachter.
    public func observe(_ report: @escaping (Bool) -> Void) {
        observer = report
        report(isVisible)
    }
}
