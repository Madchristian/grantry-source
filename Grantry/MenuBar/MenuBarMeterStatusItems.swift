import AppKit
import ManagerKit
import SwiftUI

/// Menüleisten-Elemente (TM17, Spec 2026-11-09): je eingeschaltetem Element ein eigenes Statusobjekt mit Popover.
///
/// AppKit statt `MenuBarExtra` (#482, Bewertung 2026.11.9 Mangel 2): Jedes neue Bild eines Statusobjekts kostet unter
/// macOS 26 mehrere Millisekunden (Schnappschüsse für die Menüleiste, Neuzeichnen, Szenen-Abgleich). `MenuBarExtra`
/// setzt Bild und Titel bei jedem Schnappschuss über das Erscheinungsbild noch einmal und hält geschlossene Popover am
/// Leben. Hier setzt ein Takt nur die Bilder geänderter Elemente (`MenuBarMeterBoard`); ein Popover entsteht beim
/// Öffnen und endet beim Schließen. Entfernt der Nutzer ein Element per ⌘-Ziehen, schaltet das das Element aus; die
/// Reihenfolge merkt sich macOS (`autosaveName`, Entscheidung E1).
@MainActor
final class MenuBarMeterStatusItems {
    /// Popover-Inhalt eines Elements; `close` schließt das Popover, etwa vor dem Sprung in den Task-Manager.
    typealias Content = @MainActor (MenuBarMeterKind, _ close: @escaping @MainActor () -> Void) -> AnyView

    private let meters: MenuBarMetersModel
    private let model: TaskManagerModel
    private let content: Content
    private var board = MenuBarMeterBoard()
    private var items: [MenuBarMeterKind: MenuBarMeterStatusItem] = [:]
    private var contrastObserver: NSObjectProtocol?

    init(meters: MenuBarMetersModel, model: TaskManagerModel, content: @escaping Content) {
        self.meters = meters
        self.model = model
        self.content = content
    }

    isolated deinit {
        contrastObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    /// Ab dem App-Start: folgt den Einstellungen und jedem Takt.
    func activate() {
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.board.invalidate()
                self?.refresh()
            }
        }
        refresh()
    }

    /// Liest Einstellungen und Stand unter Beobachtung; die nächste Änderung ruft erneut. Ohne eingeschaltetes Element
    /// beobachtet es nur die Einstellungen, nicht die Takte des Fensters.
    private func refresh() {
        let entries = withObservationTracking {
            MenuBarMeterKind.allCases.contains(where: meters.isShown) ? meters.entries(in: model.latestFrame) : []
        } onChange: {
            Task { @MainActor [weak self] in self?.refresh() }
        }
        apply(board.update(entries))
    }

    private func apply(_ changes: MenuBarMeterChanges) {
        for kind in changes.removed {
            items.removeValue(forKey: kind)?.remove()
        }
        let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        // Neue Statusobjekte erscheinen links der vorhandenen: umgekehrt angelegt, steht „Auslastung“ ganz links.
        for entry in changes.updated.reversed() {
            item(for: entry.kind).show(entry, increasedContrast: increasedContrast)
        }
    }

    private func item(for kind: MenuBarMeterKind) -> MenuBarMeterStatusItem {
        if let item = items[kind] { return item }
        let item = MenuBarMeterStatusItem(kind: kind, content: content) { [weak self] in
            self?.meters.setShown(false, for: kind)
        }
        items[kind] = item
        return item
    }
}

/// Ein Statusobjekt samt Popover. Das Popover schließt bei einem Klick daneben, auch in anderen Apps, und mit Esc.
@MainActor
private final class MenuBarMeterStatusItem: NSObject, NSPopoverDelegate {
    /// Ein Klick auf das Statusobjekt schließt ein offenes Popover schon beim Drücken; so lange danach öffnet er es nicht
    /// gleich wieder.
    private static let reopenDelay: TimeInterval = 0.3

    private let kind: MenuBarMeterKind
    private let content: MenuBarMeterStatusItems.Content
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var visibility: NSKeyValueObservation?
    private var outsideClicks: Any?
    private var closedAt = Date.distantPast

    init(kind: MenuBarMeterKind, content: @escaping MenuBarMeterStatusItems.Content,
         onRemoval: @escaping @MainActor () -> Void) {
        self.kind = kind
        self.content = content
        super.init()
        statusItem.autosaveName = "menuBarMeter.\(kind.rawValue)"
        statusItem.behavior = .removalAllowed
        // Ein früher per ⌘-Ziehen entferntes Element merkt sich macOS als unsichtbar; eingeschaltet ist es wieder da.
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.delegate = self
        visibility = statusItem.observe(\.isVisible) { [weak self] _, _ in
            MainActor.assumeIsolated {
                if self?.statusItem.isVisible == false { onRemoval() }
            }
        }
    }

    /// Setzt Bild und VoiceOver-Text; nur bei geänderter Anzeige aufgerufen. Das Bild ist einmal gerastert: AppKit zeichnet
    /// ein Statusobjekt je Bild mehrfach (Anzeige, Schnappschuss für die Menüleiste), ein Vektorbild jedes Mal neu
    /// (Harness: 8 % weniger Arbeit, Bewertung 2026.11.9/1510, Mangel 1).
    func show(_ entry: MenuBarMeterEntry, increasedContrast: Bool) {
        let button = statusItem.button
        let image = MenuBarMeterImage.image(reading: entry.reading, style: entry.style, showsTags: entry.showsTags,
                                            increasedContrast: increasedContrast)
        button?.image = image.rasterized(scale: button?.window?.backingScaleFactor ?? 2)
        button?.setAccessibilityLabel(entry.reading.spokenText)
    }

    func remove() {
        visibility?.invalidate()
        popover.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard Date().timeIntervalSince(closedAt) > Self.reopenDelay, let button = statusItem.button else { return }
        let controller = NSHostingController(rootView: content(kind) { [weak self] in self?.popover.performClose(nil) })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Als Schlüsselfenster schließt Esc das Popover.
        controller.view.window?.makeKey()
        button.highlight(true)
        // `transient` sieht nur Klicks in Grantry; Klicks in anderen Apps meldet der globale Monitor (ohne Rechte).
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        outsideClicks.map(NSEvent.removeMonitor)
        outsideClicks = nil
        // Der Inhalt endet mit dem Popover: Geschlossen wertet er keinen Takt mehr aus.
        popover.contentViewController = nil
        statusItem.button?.highlight(false)
    }
}

private extension NSImage {
    /// Dasselbe Vorlagenbild als Bitmap mit `scale` Pixeln je Punkt; ohne Grafikkontext unverändert.
    func rasterized(scale: CGFloat) -> NSImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                            pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return self }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = isTemplate
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
