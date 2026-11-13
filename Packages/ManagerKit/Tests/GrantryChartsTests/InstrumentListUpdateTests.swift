import Observation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Eine Zeile, die die Gruppe wechselt, zeigt danach ihren neuen Inhalt (#617): Nach „Risiko akzeptieren“ rückt die App
/// von „Mit Befund“ nach „Übrige“ und verliert „prüfen“ und den Befund-Punkt. Die gezeichnete Zeile und ihr Wert für
/// VoiceOver dürfen nicht beim alten Inhalt stehen bleiben – in beide Richtungen (Rücknahme der Annahme).
@MainActor
@Suite(.serialized) struct InstrumentListUpdateTests {
    @Observable @MainActor
    final class Model {
        var sections: [InstrumentListSection<String>]
        init(_ sections: [InstrumentListSection<String>]) { self.sections = sections }
    }

    struct Host: View {
        let model: Model
        @State var selection: String? = "risk"

        var body: some View {
            InstrumentList("Apps", count: "2", sections: model.sections, selection: $selection)
        }
    }

    private static let review = InstrumentBadge("prüfen", tone: .finding, spoken: "prüfen, Schweregrad mittel")
    private static let accepted = InstrumentBadge("akzeptiert", tone: .neutral, spoken: "Risiko akzeptiert")

    /// Wie `AppsBoardMapping.sections`: auffällige Zeilen in „Mit Befund“, die übrigen in „Übrige“.
    private static func sections(riskFlagged: Bool, riskAccepted: Bool) -> [InstrumentListSection<String>] {
        let risk = InstrumentListItem(id: "risk", content: InstrumentRowContent(
            symbol: "app", title: "Risiko-App", detail: "Direkt",
            badges: (riskFlagged ? [review] : []) + (riskAccepted ? [accepted] : []), finding: riskFlagged))
        let calm = InstrumentListItem(id: "calm", content: InstrumentRowContent(symbol: "app", title: "Ruhige App",
                                                                               detail: "App Store"))
        return riskFlagged
            ? [InstrumentListSection(id: "befund", title: "Mit Befund", finding: true, items: [risk]),
               InstrumentListSection(id: "uebrige", title: "Übrige", items: [calm])]
            : [InstrumentListSection(id: "uebrige", title: "Übrige", items: [calm, risk])]
    }

    private static func riskValue(_ nodes: [AccessibilityTree.Node]) -> String? {
        nodes.first { $0.label == "Risiko-App" }?.value
    }

    /// Annahme: erst kommt „akzeptiert“ dazu (Zustand der Überwachung), danach fällt der Befund weg (Anzeige-Daten).
    @Test func acceptedRowLeavesFindingGroupAndDropsReview() async throws {
        let model = Model(Self.sections(riskFlagged: true, riskAccepted: true))
        let expected = "Risiko akzeptiert. Direkt"
        let (before, after) = try await AccessibilityTree.nodes(of: Host(model: model)) {
            model.sections = Self.sections(riskFlagged: false, riskAccepted: true)
        } isSettled: { Self.riskValue($0) == expected }
        #expect(Self.riskValue(before) == "auffällig, prüfen, Schweregrad mittel, Risiko akzeptiert. Direkt")
        #expect(Self.riskValue(after) == expected, "\(after)")
    }

    /// Köpfe und Zeilen in Anzeigereihenfolge mit eindeutigen Kennungen; eine Zeile behält ihre Kennung in jeder Gruppe.
    @Test func entriesKeepRowIdentityAcrossGroups() {
        let flagged = InstrumentListEntry.entries(Self.sections(riskFlagged: true, riskAccepted: false)).map(\.id)
        let calm = InstrumentListEntry.entries(Self.sections(riskFlagged: false, riskAccepted: true)).map(\.id)
        #expect(flagged == [.header("befund"), .row("risk"), .header("uebrige"), .row("calm")])
        #expect(calm == [.header("uebrige"), .row("calm"), .row("risk")])
    }

    /// Rücknahme: Die Zeile kehrt nach „Mit Befund“ zurück und nennt den Befund wieder.
    @Test func revokedRowReturnsToFindingGroupWithReview() async throws {
        let model = Model(Self.sections(riskFlagged: false, riskAccepted: false))
        let expected = "auffällig, prüfen, Schweregrad mittel. Direkt"
        let (before, after) = try await AccessibilityTree.nodes(of: Host(model: model)) {
            model.sections = Self.sections(riskFlagged: true, riskAccepted: false)
        } isSettled: { Self.riskValue($0) == expected }
        #expect(Self.riskValue(before) == "Direkt")
        #expect(Self.riskValue(after) == expected, "\(after)")
    }
}
