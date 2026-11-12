import SwiftUI
import Testing
@testable import GrantryCharts

/// Felder in Detailansichten für VoiceOver (#563): Jedes Feld meldet Titel als Beschriftung und Inhalt als Wert. Mit
/// `accessibilityElement(children: .combine)` ging unter macOS 27 der auswählbare Inhalt verloren: Das Feld „Art“ im
/// Detail eines Sockets meldete sich als AXUnknown nur mit „Art“ (Abnahme 2026.11.10/1572, Befund 1).
@MainActor
@Suite(.serialized) struct DetailAccessibilityTests {
    private static func staticText(_ label: String, _ value: String) -> AccessibilityTree.Node {
        AccessibilityTree.Node(role: "AXStaticText", label: label, value: value)
    }

    /// Schließen-Knopf eines Banners (LB-5.5, #556; App, Galerie und Aufräumen gemeinsam): nur Symbol im Bild, für
    /// VoiceOver ein Knopf „Meldung schließen“.
    @Test func bannerDismissButtonReadsItsTitle() async throws {
        let nodes = try await AccessibilityTree.nodes(of: InstrumentBanner("Entfernen fehlgeschlagen", message: "Grund",
                                                                           tone: .critical) {
            BannerDismissButton {}
        })
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXButton", label: "Meldung schließen", value: "")))
    }

    @Test func textFieldReadsTitleAndSelectableValue() async throws {
        let nodes = try await AccessibilityTree.nodes(of: VStack {
            DetailEntry("Art", value: "TCP · IPv6 · lauscht", isCode: true)
            DetailEntry("Zustand", value: "lauscht", tone: .positive)
        })
        #expect(nodes == [Self.staticText("Art", "TCP · IPv6 · lauscht"), Self.staticText("Zustand", "lauscht")])
    }

    /// Eigener Inhalt wie der auswählbare Pfad oder die Signatur mit Symbol.
    @Test func entryWithOwnContentReadsTitleAndGivenValue() async throws {
        let nodes = try await AccessibilityTree.nodes(of: VStack {
            DetailEntry("Pfad", value: "/usr/local/bin/beispiel") {
                Text(verbatim: "/usr/local/bin/beispiel").textSelection(.enabled).truncationMode(.middle)
            }
            DetailEntry("Signatur", value: "Ad hoc") {
                Label {
                    Text(verbatim: "Ad hoc")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
        })
        #expect(nodes == [Self.staticText("Pfad", "/usr/local/bin/beispiel"), Self.staticText("Signatur", "Ad hoc")])
    }

    /// Mit Bedienelement bleibt es ein Knopf, der Titel steht vor seiner Beschriftung.
    @Test func entryWithControlKeepsTheControl() async throws {
        let nodes = try await AccessibilityTree.nodes(of: DetailEntry("Autostart-Eintrag") {
            Button("com.example.agent") {}
        })
        #expect(nodes == [AccessibilityTree.Node(role: "AXButton", label: "Autostart-Eintrag, com.example.agent",
                                                 value: "")])
    }

    /// Knopfzeile unter dem Kopf (Spec § 11.2 d): Die Knöpfe bleiben Knöpfe, die laufende Aktion liest „läuft“ mit ihrem
    /// Text als Wert statt eines Textes ohne Beschriftung.
    @Test func actionBarKeepsButtonsAndReadsTheRunningAction() async throws {
        let nodes = try await AccessibilityTree.nodes(of: DetailActions(runningText: "Wird deaktiviert …") {
            Button("Deaktivieren") {}
            Button("Entfernen …") {}
        })
        #expect(nodes == [AccessibilityTree.Node(role: "AXButton", label: "Deaktivieren", value: ""),
                          AccessibilityTree.Node(role: "AXButton", label: "Entfernen …", value: ""),
                          Self.staticText("läuft", "Wird deaktiviert …")], "\(nodes)")
    }

    /// Ohne laufende Aktion nur die Knöpfe.
    @Test func actionBarWithoutRunningActionShowsOnlyTheButtons() async throws {
        let nodes = try await AccessibilityTree.nodes(of: DetailActions {
            Button("Reste anzeigen") {}
        })
        #expect(nodes == [AccessibilityTree.Node(role: "AXButton", label: "Reste anzeigen", value: "")], "\(nodes)")
    }

    /// Sprungzeile (Spec § 11.2 e): ein Knopf mit dem Namen als Beschriftung, Zustand und Detail als Wert.
    @Test func jumpRowIsOneButtonWithNameAndState() async throws {
        let content = InstrumentRowContent(symbol: "internaldrive", title: "Festplattenvollzugriff", detail: "Terminal",
                                           status: StatusItem("erlaubt", tone: .positive))
        let nodes = try await AccessibilityTree.nodes(of: JumpRow(content, destination: "Berechtigungen") {})
        #expect(nodes == [AccessibilityTree.Node(role: "AXButton", label: "Festplattenvollzugriff",
                                                 value: "erlaubt. Terminal")], "\(nodes)")
    }

    /// Herkunft im Detail einer Erweiterung: Titel und Wert als ein Element statt zweier getrennter, der Wert als
    /// AXUnknown ohne Titel.
    @Test func extensionFactsReadTitleAndValue() async throws {
        let facts = [ExtensionDetailContent.Fact(title: "Hersteller", value: "Beispiel Labs"),
                     ExtensionDetailContent.Fact(title: "Team-ID", value: "A1B2C3D4E5", isCode: true),
                     ExtensionDetailContent.Fact(title: "Pfad", value: "/Library/Extensions/Beispiel.kext", isCode: true)]
        let content = ExtensionDetailContent(id: "beispiel", symbol: "cpu", title: "Beispiel",
                                             subtitle: "Kernel-Erweiterung", state: StatusItem("geladen", tone: .neutral),
                                             rating: nil, permission: "Läuft im Kern.", findings: [], acceptance: nil,
                                             facts: facts)
        let nodes = try await AccessibilityTree.nodes(of: ExtensionDetailPanel(content: content) {
            EmptyView()
        } actions: {
            EmptyView()
        }, size: CGSize(width: 900, height: 500))
        for fact in facts {
            #expect(nodes.contains(Self.staticText(fact.title, fact.value)), "Herkunft „\(fact.title)“: \(nodes)")
        }
    }

    /// Takt in der Tab-Leiste: Das Menü trägt seinen Titel selbst; über den sichtbaren Text allein (AXTitleUIElement)
    /// sehen die UI-Tests der Abnahme ein Bedienelement ohne Beschriftung (#566).
    @Test func titledMenuCarriesItsTitle() async throws {
        let nodes = try await AccessibilityTree.nodes(of: TitledMenuPicker("Takt", selection: .constant(1),
                                                                           options: [(1, "1 s"), (2, "2 s")]))
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXPopUpButton", label: "Takt", value: "1 s")),
                "\(nodes)")
    }
}
