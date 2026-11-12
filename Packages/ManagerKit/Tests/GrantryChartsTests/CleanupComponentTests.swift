import SwiftUI
import Testing
@testable import GrantryCharts

/// Zentrale Bausteine des Bereichs Aufräumen (LB-4.2, #548; Spec 2026-11-10 § 11.4): Aktionsleiste unten, Gruppenkopf
/// mit Summe, aufklappbarer Kopf (c, g) und Ausgang je Eintrag (d). Jedes Element liest Beschriftung und Wert (#563).
@MainActor
@Suite struct CleanupComponentTests {
    @Test func groupHeaderReadsCountAndSum() {
        #expect(SelectionGroupHeader.spokenValue(count: 1, size: nil) == "1 Eintrag")
        #expect(SelectionGroupHeader.spokenValue(count: 3, size: "1,5 GB") == "3 Einträge, Summe 1,5 GB")
    }

    @Test func disclosureReadsValueAndState() {
        #expect(DisclosureSection<EmptyView, EmptyView>.spokenValue("12 GB", isExpanded: true) == "12 GB, aufgeklappt")
        #expect(DisclosureSection<EmptyView, EmptyView>.spokenValue("", isExpanded: false) == "zugeklappt")
    }

    @Test func outcomeRowReadsStateAndReason() {
        #expect(OutcomeRow.spokenValue(StatusItem("übersprungen", tone: .finding), reason: "wird benutzt")
            == "übersprungen, wird benutzt")
        #expect(OutcomeRow.spokenValue(StatusItem("aufgeräumt", tone: .positive), reason: nil) == "aufgeräumt")
    }
}

/// Was VoiceOver im Gerüst liest: Umfang der Auswahl, laufende Aktion, Gruppenkopf, Aufklapp-Knopf (Spec § 7).
@MainActor
@Suite(.serialized) struct CleanupBoardAccessibilityTests {
    @Test func boardReadsScopeRunningActionGroupAndDisclosure() async throws {
        let nodes = try await AccessibilityTree.nodes(of: CleanupBoardSample(), size: CGSize(width: 900, height: 600))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "Umfang",
                                                      value: "Ausgewählt: 1 Objekt (12 KB)")), "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "läuft",
                                                      value: "Wird in den Papierkorb gelegt …")), "\(nodes)")
        #expect(nodes.contains { $0.label == "com.example.scanner" && $0.value == "1 Eintrag, Summe 12 KB" },
                "\(nodes)")
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Caches" && $0.value == "1,4 GB, zugeklappt" },
                "\(nodes)")
        #expect(nodes.contains { $0.label == "Einstellungen" && $0.value == "übersprungen, wird benutzt" }, "\(nodes)")
    }
}

/// App-Reste (LB-4.2, #548): Häkchenzeile liest Zustand, Hinweis „Zuordnung unsicher“, Größe und Ort; Erweiterung ohne
/// App mit Befund; Spur mit Titel und Anteil; Umschalter mit gewähltem Segment.
@MainActor
@Suite(.serialized) struct LeftoversAccessibilityTests {
    @Test func resultReadsRowsExtensionsAndStand() async throws {
        let nodes = try await AccessibilityTree.nodes(of: SnapshotGallery.leftovers(.result),
                                                      size: SnapshotGallery.leftoversSize)
        #expect(nodes.contains { $0.label == "Programmdaten"
            && $0.value == "nicht ausgewählt, Zuordnung unsicher, 84 MB, ~/Library/Application Support/Notizblock" },
                "\(nodes)")
        #expect(nodes.contains { $0.label == "Caches" && $0.value.hasPrefix("ausgewählt, 1,4 GB") }, "\(nodes)")
        #expect(nodes.contains { $0.label == "Scanner-Treiber" && $0.value.hasPrefix("auffällig") }, "\(nodes)")
        #expect(nodes.contains { $0.label == "Suche vollständig" && $0.value.hasSuffix("alle Orte gelesen · Suche 14:32") }, "\(nodes)")
        #expect(nodes.contains { $0.label == "com.example.notes" && $0.value == "2 Einträge, Summe 86 MB" }, "\(nodes)")
    }
}

/// Kleines Gerüst mit allen Bausteinen und erfundenen Daten.
private struct CleanupBoardSample: View {
    @State private var isExpanded = false

    var body: some View {
        CleanupBoard(head: InventoryHead(verdict: "Reste von 1 App", finding: true, items: [], facts: "1 Fund · 12 KB"),
                     progress: CleanupProgress(title: "Suche vollständig", detail: "alle Orte gelesen", fraction: 1,
                                               tone: .positive)) {
            Text(verbatim: "Umschalter")
        } banner: {
            InstrumentBanner("Ergebnis", message: "1 übersprungen", tone: .finding)
        } content: {
            CleanupFindingList {
                SelectionGroupHeader(title: "com.example.scanner", count: 1, size: "12 KB")
                SelectionCheckRow("Einstellungen", detail: "~/Library/Preferences/x.plist", size: "12 KB",
                                  isOn: .constant(true))
                DisclosureSection("Caches", value: "1,4 GB", isExpanded: $isExpanded) {
                    Text(verbatim: "Caches")
                } content: {
                    Text(verbatim: "Inhalt")
                }
                OutcomeRow(StatusItem("übersprungen", tone: .finding), target: "Einstellungen", reason: "wird benutzt")
            }
        } bar: {
            InstrumentActionBar(scope: "Ausgewählt: 1 Objekt (12 KB)", runningText: "Wird in den Papierkorb gelegt …") {
                Button("Erneut suchen") {}
            } trailing: {
                Button("In den Papierkorb legen …") {}.disabled(true)
            }
        }
    }
}
