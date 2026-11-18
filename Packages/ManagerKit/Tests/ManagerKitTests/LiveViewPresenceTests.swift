import Foundation
import Testing
@testable import ManagerKit

/// #662: Fenster und Popover mit Livewerten melden, solange sie messen; die verteilte Komplettprüfung schiebt dann auf.
/// Gemeldet wird nur der Wechsel zwischen „keine“ und „mindestens eine“ Ansicht.
@MainActor
@Suite struct LiveViewPresenceTests {
    @Test func windowAndPopoverCountUntilTheLastOneStops() {
        let presence = LiveViewPresence()
        var reports: [Bool] = []
        presence.observe { reports.append($0) }
        let window = UUID(), popover = UUID()

        presence.setMeasuring(true, for: window)
        presence.setMeasuring(true, for: popover)
        presence.setMeasuring(false, for: window)
        #expect(presence.isVisible, "Popover noch offen")
        presence.setMeasuring(false, for: popover)
        #expect(!presence.isVisible)
        #expect(reports == [false, true, false], "Anfangsstand, dann nur Wechsel")
    }

    /// `MeasuresWhileVisible` ruft `stop` auch doppelt (verdeckt, dann verschwunden); das zählt nur einmal.
    @Test func repeatedReportsOfTheSameViewAreIdempotent() {
        let presence = LiveViewPresence()
        var reports: [Bool] = []
        let view = UUID()
        presence.setMeasuring(true, for: view)
        presence.observe { reports.append($0) }
        presence.setMeasuring(true, for: view)
        presence.setMeasuring(false, for: view)
        presence.setMeasuring(false, for: view)
        #expect(reports == [true, false])
    }
}
