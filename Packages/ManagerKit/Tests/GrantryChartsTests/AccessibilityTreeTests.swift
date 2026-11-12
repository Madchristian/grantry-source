import AppKit
import SwiftUI
import Testing

/// Der Helfer schaltet für die Dauer eines Tests die erweiterte Oberfläche ein. Verschränkte Aufrufe aus parallelen
/// Suites dürfen sie danach nicht eingeschaltet lassen, sonst zeichnen spätere Snapshots native Schalter anders (#546).
@MainActor
@Suite(.serialized) struct AccessibilityTreeTests {
    @Test func interleavedCallsRestoreTheEnhancedInterface() async throws {
        let application = NSApplication.shared
        // Beide Ansichten sind leer: Jeder Aufruf wartet im Helfer, die Aufrufe verschränken sich.
        let before = application.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false
        async let first = AccessibilityTree.nodes(of: EmptyView())
        async let second = AccessibilityTree.nodes(of: EmptyView())
        _ = try await (first, second)
        #expect(application.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false == before)
    }
}
