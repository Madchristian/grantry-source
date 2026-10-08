import AppKit
import ManagerKit
import SwiftUI

/// Symbol der Menüleiste: `shield.lefthalf.filled`, bei ungelesenen Änderungen mit Badge oben rechts. Als
/// Vorlagenbild gezeichnet (nur Deckkraft zählt), damit das System es in heller und dunkler Menüleiste passend
/// einfärbt; die Ziffer ist aus dem Badge ausgestanzt.
enum MenuBarIcon {
    private static let symbolName = "shield.lefthalf.filled"
    private static let pointSize: CGFloat = 15
    private static let countDiameter: CGFloat = 11
    private static let dotDiameter: CGFloat = 7
    /// Freier Rand um das Badge, damit es sich vom Schild abhebt.
    private static let gap: CGFloat = 1.5

    static func image(for badge: MenuBarBadge) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSImage() }
        let diameter: CGFloat = switch badge {
        case .none: 0
        case .count: countDiameter
        case .dot: dotDiameter
        }
        guard diameter > 0 else {
            symbol.isTemplate = true
            return symbol
        }
        let overhang = diameter / 2
        let size = NSSize(width: symbol.size.width + overhang, height: max(symbol.size.height, diameter))
        let image = NSImage(size: size, flipped: false) { bounds in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            let badgeRect = NSRect(
                x: bounds.maxX - diameter, y: bounds.maxY - diameter, width: diameter, height: diameter
            )
            guard let context = NSGraphicsContext.current else { return false }
            context.compositingOperation = .clear
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -gap, dy: -gap)).fill()
            context.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            if let text = badge.text {
                context.compositingOperation = .destinationOut
                let string = NSAttributedString(string: text, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                    .foregroundColor: NSColor.black,
                ])
                let textSize = string.size()
                string.draw(at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2))
                context.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Beschriftung des `MenuBarExtra`: Symbol mit Badge (Punkt auch während einer Beobachtung) und VoiceOver-Text mit der
/// genauen Zahl. Liest die Zahl erst
/// hier, damit eine Änderung nur die Beschriftung neu zeichnet und nicht den ganzen `App.body`.
struct MenuBarLabel: View {
    let appModel: AppModel
    /// Erhält hier die `openWindow`-Aktion – die Beschriftung existiert, solange die App läuft.
    let navigator: MainWindowNavigator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let unreadCount = appModel.monitoring.unreadCount
        let isObserving = appModel.observations.active != nil
        Image(nsImage: MenuBarIcon.image(for: MenuBarBadge(unreadCount: unreadCount, isObserving: isObserving)))
            .accessibilityLabel(MenuBarBadge.accessibilityLabel(unreadCount: unreadCount, isObserving: isObserving))
            .onAppear { navigator.register(openWindow) }
    }
}
