import AppKit
import SwiftUI
import Testing

/// Der Helfer schaltet für die Dauer eines Tests die erweiterte Oberfläche ein. Verschränkte Aufrufe aus parallelen
/// Suites dürfen sie danach nicht eingeschaltet lassen, sonst zeichnen spätere Snapshots native Schalter anders (#546).
@MainActor
@Suite(.serialized) struct AccessibilityTreeTests {
    @Test func interleavedCallsRestoreTheEnhancedInterface() async throws {
        let application = NSApplication.shared
        // Gelesen wird nur, wenn keine andere Suite den Helfer gerade nutzt; sonst hielte sie den Schalter an (#617).
        try await Self.waitUntilIdle()
        let before = application.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false
        // Beide Ansichten sind leer: Jeder Aufruf wartet im Helfer, die Aufrufe verschränken sich.
        async let first = AccessibilityTree.nodes(of: EmptyView())
        async let second = AccessibilityTree.nodes(of: EmptyView())
        _ = try await (first, second)
        try await Self.waitUntilIdle()
        #expect(application.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false == before)
    }

    private static func waitUntilIdle() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while AccessibilityTree.isInUse, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!AccessibilityTree.isInUse, "Bedienungshilfen-Baum bleibt 30 s belegt")
    }
}
