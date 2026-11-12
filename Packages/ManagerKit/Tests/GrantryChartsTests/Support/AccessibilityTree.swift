import AppKit
import SwiftUI

/// Bedienungshilfen-Baum einer Ansicht, wie ihn VoiceOver und die UI-Tests der Abnahme lesen: Rolle, Beschriftung
/// (AXDescription) und Wert (AXValue) je Element. SwiftUI baut den Baum erst, wenn ein Bedienungshilfen-Client da ist;
/// dafür steht die Ansicht in einem Fenster hinter allen anderen, und die App meldet die erweiterte Oberfläche wie bei
/// laufendem VoiceOver (#563).
@MainActor
enum AccessibilityTree {
    struct Node: Equatable, CustomStringConvertible {
        let role: String
        let label: String
        let value: String

        var description: String { "\(role) „\(label)“ = „\(value)“" }
    }

    static func nodes(of view: some View, size: CGSize = CGSize(width: 600, height: 400)) async throws -> [Node] {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderBack(nil)
        enterEnhancedInterface()
        defer {
            leaveEnhancedInterface()
            window.close()
        }
        var nodes: [Node] = []
        for _ in 0..<50 {
            nodes = collect(host.accessibilityChildren() ?? [])
            if !nodes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nodes
    }

    private static let enhancedKey = "accessibilityEnhancedUserInterface"
    /// Laufende Aufrufe und der Wert vor dem ersten: Tests aus parallelen Suites verschränken sich an den `await`; nur
    /// der letzte stellt den Ausgangswert wieder her. Sonst bliebe die erweiterte Oberfläche an, und spätere Snapshots
    /// zeichneten native Schalter anders (#546).
    private static var enhancedUsers = 0
    private static var enhancedBefore = false

    private static func enterEnhancedInterface() {
        let application = NSApplication.shared
        if enhancedUsers == 0 { enhancedBefore = application.value(forKey: enhancedKey) as? Bool ?? false }
        enhancedUsers += 1
        application.setValue(true, forKey: enhancedKey)
    }

    private static func leaveEnhancedInterface() {
        enhancedUsers -= 1
        if enhancedUsers == 0 { NSApplication.shared.setValue(enhancedBefore, forKey: enhancedKey) }
    }

    /// Alle Elemente unter `elements` in Lesereihenfolge; leere Gruppen ohne Beschriftung und Wert fallen weg.
    private static func collect(_ elements: [Any]) -> [Node] {
        elements.flatMap { element -> [Node] in
            guard let object = element as? NSObject else { return [] }
            let node = Node(role: string(object, "accessibilityRole"), label: string(object, "accessibilityLabel"),
                            value: string(object, "accessibilityValue"))
            let children = collect(object.value(forKey: "accessibilityChildren") as? [Any] ?? [])
            return node.label.isEmpty && node.value.isEmpty ? children : [node] + children
        }
    }

    private static func string(_ object: NSObject, _ key: String) -> String {
        guard object.responds(to: NSSelectorFromString(key)) else { return "" }
        return object.value(forKey: key).map { "\($0)" } ?? ""
    }
}
