import SwiftUI
import Testing
@testable import GrantryCharts

/// Zentrale Bausteine der Liste-Detail-Ansichten (LB-1.2, #536): Aufteilung, Tastaturbedienung der Auswahlliste und was
/// VoiceOver liest – jedes Element mit Beschriftung und Wert, nie nur dem Titel (Lehre aus #563).
@MainActor
@Suite struct LagebildComponentTests {
    // MARK: - ShieldBadge

    /// Drei Schildformen (Spec § 11.3 c): Häkchen nur mit Urteil „ruhig“, Ausrufezeichen beim Befund, ohne Zeichen
    /// („offen“) für Zustände ohne Urteil – nichts davon darf wie eine Entwarnung wirken.
    @Test func shieldFormsDrawDistinctSymbols() {
        #expect(ShieldForm.calm.symbolName == "checkmark.shield.fill")
        #expect(ShieldForm.finding.symbolName == "exclamationmark.shield.fill")
        #expect(ShieldForm.open.symbolName == "shield.fill")
        #expect(ShieldForm(finding: true) == .finding)
        #expect(ShieldForm(finding: false) == .calm)
    }

    /// Nur der Befund trägt den Bernstein-Punkt; die offene Form bleibt ohne.
    @Test func onlyTheFindingShieldCarriesTheDot() {
        #expect(ShieldForm.finding.showsFindingDot)
        #expect(!ShieldForm.calm.showsFindingDot)
        #expect(!ShieldForm.open.showsFindingDot)
    }

    // MARK: - JumpTile

    /// Zählkachel mit Sprung (LB-3.2, #544): VoiceOver liest Titel als Beschriftung, Zahl und Detail als Wert und das
    /// Ziel als Hinweis; der Tooltip nennt den Bereich.
    @Test func jumpTileReadsValueDetailAndDestination() {
        #expect(JumpTile.spokenValue(value: 1234, detail: "1 hoch · 1 mittel") == "\(1234.formatted()). 1 hoch · 1 mittel")
        #expect(JumpTile.spokenValue(value: 0, detail: "") == "0")
        #expect(JumpTile.helpText(destination: "Netzwerk") == "In „Netzwerk“ zeigen")
        #expect(JumpTile.defaultHint(destination: "Netzwerk") == "Zeigt den Bereich „Netzwerk“.")
    }

    // MARK: - InstrumentSplit

    /// Mit Platz steht die Liste in `column.wide`; das Detail bekommt den Rest.
    @Test func splitGivesTheListItsIdealWidthWhenThereIsRoom() {
        #expect(InstrumentSplitLayout.listWidth(available: 1100) == InstrumentSize.columnWide)
    }

    /// Wird es eng, gibt die Liste nach, bis das Detail seine Mindestbreite hat – erst dann auch das Detail.
    @Test func splitShrinksTheListBeforeTheDetail() {
        let available = InstrumentSize.listMin + InstrumentSpacing.panel + InstrumentSize.detailMin + 40
        #expect(InstrumentSplitLayout.listWidth(available: available) == InstrumentSize.listMin + 40)
    }

    /// Nie breiter als der Platz: unter der Summe der Mindestbreiten bleibt die Liste bei ihrer Mindestbreite und das
    /// Detail wird schmaler, statt rechts aus dem Fenster zu ragen (#507).
    @Test func splitNeverOverflowsTheAvailableWidth() {
        let available: CGFloat = 500
        let list = InstrumentSplitLayout.listWidth(available: available)
        #expect(list == InstrumentSize.listMin)
        #expect(InstrumentSplitLayout.detailWidth(available: available) == available - list - InstrumentSpacing.panel)
    }

    // MARK: - InstrumentList: Tastatur

    private let ids = ["a", "b", "c"]

    @Test func arrowDownSelectsTheNextRowAndStopsAtTheEnd() {
        #expect(InstrumentListNavigation.target(from: nil, in: ids, direction: .down) == "a")
        #expect(InstrumentListNavigation.target(from: "a", in: ids, direction: .down) == "b")
        #expect(InstrumentListNavigation.target(from: "c", in: ids, direction: .down) == "c")
    }

    @Test func arrowUpSelectsThePreviousRowAndStopsAtTheStart() {
        #expect(InstrumentListNavigation.target(from: nil, in: ids, direction: .up) == "c")
        #expect(InstrumentListNavigation.target(from: "c", in: ids, direction: .up) == "b")
        #expect(InstrumentListNavigation.target(from: "a", in: ids, direction: .up) == "a")
    }

    /// Fällt die gewählte Zeile aus der Liste (Suche, Filter), beginnt die Tastatur wieder vorn bzw. hinten.
    @Test func arrowKeysRecoverFromASelectionThatIsNoLongerListed() {
        #expect(InstrumentListNavigation.target(from: "x", in: ids, direction: .down) == "a")
        #expect(InstrumentListNavigation.target(from: "x", in: ids, direction: .up) == "c")
        #expect(InstrumentListNavigation.target(from: nil, in: [String](), direction: .down) == nil)
    }

    /// Die Reihenfolge der Tastatur ist die der Anzeige über alle Gruppen.
    @Test func listOrderRunsThroughAllSections() {
        let sections = [
            InstrumentListSection(id: "1", title: "Mit Befund", items: [Self.item("b"), Self.item("a")]),
            InstrumentListSection(id: "2", title: "Übrige", items: [Self.item("c")]),
        ]
        #expect(InstrumentListSection.orderedIDs(sections) == ["b", "a", "c"])
    }

    // MARK: - VoiceOver

    /// Listenzeile: Name als Beschriftung, als Wert „auffällig, Zustand, Badges. Detail“.
    @Test func listRowReadsStateBadgesAndDetail() {
        let content = InstrumentRowContent(symbol: "record.circle", title: "Bildschirmrekorder",
                                           detail: "Bildschirmaufnahme, Mikrofon",
                                           badges: [InstrumentBadge("prüfen", tone: .finding,
                                                                    spoken: "prüfen, mittlerer Schweregrad")],
                                           status: StatusItem("erlaubt", tone: .positive), finding: true)
        #expect(content.spokenValue == "auffällig, erlaubt, prüfen, mittlerer Schweregrad. Bildschirmaufnahme, Mikrofon")
        #expect(InstrumentRowContent(symbol: "note", title: "Notizen", detail: "Kalender").spokenValue == "Kalender")
    }

    /// Ein Badge ohne eigene Sprechform liest seinen Titel.
    @Test func badgeSpeaksItsTitleByDefault() {
        #expect(InstrumentBadge("neu", tone: .neutral).spoken == "neu")
    }

    /// Hinweiszeile: Art als Beschriftung, Text als Wert.
    @Test func noteReadsKindAndText() {
        #expect(InstrumentNote.Kind.info.spoken == "Hinweis")
        #expect(InstrumentNote.Kind.locked.spoken == "gesperrt")
        #expect(InstrumentNote.Kind.finding.spoken == "auffällig")
        #expect(InstrumentNote.Kind.critical.spoken == "Fehler")
    }

    /// Häkchenzeile: Schalter mit Zustand, Hinweis, Größe und Ort; gesperrt nennt sie den Grund.
    @Test func checkRowReadsStateHintSizeAndDetail() {
        #expect(SelectionCheckRow.spokenValue(isOn: true, detail: "~/Library/Caches/com.example", size: "1,4 GB",
                                              hint: StatusItem("groß", tone: .finding), lockedReason: nil)
                == "ausgewählt, groß, 1,4 GB, ~/Library/Caches/com.example")
        #expect(SelectionCheckRow.spokenValue(isOn: false, detail: "Einstellungen", size: "12 KB", hint: nil,
                                              lockedReason: nil)
                == "nicht ausgewählt, 12 KB, Einstellungen")
        #expect(SelectionCheckRow.spokenValue(isOn: false, detail: "/Library/LaunchDaemons", size: "4 KB", hint: nil,
                                              lockedReason: "Systemordner – nur mit Helper")
                == "gesperrt: Systemordner – nur mit Helper, 4 KB")
    }

    /// Fortschritt und Abdeckung: Anteil und Detail; ohne Anteil nur das Detail („Dauer noch unbekannt“).
    @Test func progressSpurReadsShareAndDetail() {
        let percent = 0.42.formatted(.percent.precision(.fractionLength(0)))
        #expect(ProgressSpur<EmptyView>.spokenValue(fraction: 0.42, detail: "142 von 340") == "\(percent), 142 von 340")
        #expect(ProgressSpur<EmptyView>.spokenValue(fraction: nil, detail: "Dauer noch unbekannt") == "Dauer noch unbekannt")
    }

    /// Sprungzeile: Hinweis und Tooltip nennen das Ziel.
    @Test func jumpRowNamesItsDestination() {
        #expect(JumpRow<InstrumentRowIcon>.spokenHint(destination: "Autostart") == "Zeigt den Eintrag im Bereich „Autostart“.")
        #expect(JumpRow<InstrumentRowIcon>.helpText(destination: "Autostart") == "In „Autostart“ zeigen")
    }

    /// Ein Klick auf die Sprungzeile ruft ihre Aktion.
    @Test func jumpRowRunsItsAction() {
        var jumped = 0
        let row = JumpRow(InstrumentRowContent(symbol: "gearshape.2", title: "com.example.agent", detail: "LaunchAgent"),
                          destination: "Autostart") { jumped += 1 }
        row.action()
        #expect(jumped == 1)
    }

    private static func item(_ id: String) -> InstrumentListItem<String> {
        InstrumentListItem(id: id, content: InstrumentRowContent(symbol: "app", title: id, detail: ""))
    }
}

#if DEBUG
/// Render-Wächter für die Auswahlliste: Ein Wechsel der Auswahl wertet die Zeilen ohne Übergang aus, zwischen zwei
/// Wechseln geschieht nichts, und keine Zeile zeichnet per `Canvas` (jeder `Canvas` legt einen großen Grafikpuffer an,
/// #521, PR 523).
@MainActor
@Suite(.serialized) struct LagebildRenderGuardTests {
    @Test func selectionChangesRedrawRowsOnceWithoutAnimation() {
        let sections = SnapshotGallery.lagebildSections
        let ids = InstrumentListSection.orderedIDs(sections)
        let report = RenderGuard.measure(size: CGSize(width: 900, height: 600)) { tick in
            InstrumentSplit {
                InstrumentList("Apps", count: "\(ids.count)", sections: sections,
                               selection: .constant(ids[tick % ids.count]))
            } detail: {
                DetailPanel {
                    DetailGroup("Angaben") { DetailEntry("Takt", value: "\(tick)") }
                }
            }
        }
        #expect(report.violations().isEmpty, "\(report.violations())")
        #expect(report.ticks.allSatisfy { $0.update["InstrumentListRow", default: .init()].bodies >= 1 })
        #expect(report.ticks.allSatisfy { $0.update["InstrumentListRow", default: .init()].draws == 0 })
        #expect(report.ticks.allSatisfy { $0.update["InstrumentListRow", default: .init()].animatedUpdates == 0 })
    }
}
#endif
