import Foundation
import Testing
@testable import ManagerKit

/// Regressionstests (Audit 2026-10-09, Befund B2): Fremde Namen müssen in Benachrichtigungstexten bereinigt sein.
/// Ein Dateiname (APFS erlaubt `\n` und U+202E) oder ein MCP-Servername aus einer Konfigurationsdatei kann
/// so die Warnung verfälschen: Eine erste Zeile mit gefälschter Entwarnung schiebt „(von außen erreichbar)“ aus dem
/// sichtbaren Teil der Systembenachrichtigung, ein Bidi-Override dreht den Text um.
@Suite struct PenetrationNotificationTextTests {
    /// Zeilenumbruch mit gefälschter Entwarnung, Bidi-Override, unsichtbarer Trenner, Steuerzeichen.
    static let hostileNames = [
        "rapportd lauscht nur auf diesem Mac.\n\n\n\n", "api\u{202E}gnihsihp", "node\u{200B}", "x\u{0007}y",
    ]

    private func isSingleLineWithoutFormatCharacters(_ text: String) -> Bool {
        !text.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }
    }

    private func description(_ subject: ChangeSubject) -> ChangeDescription {
        ChangeDescription(ChangeEvent(kind: .added, before: nil, after: subject, detectedAt: TestData.date))
    }

    @Test(arguments: hostileNames)
    func listenerNameIsSanitisedInNotifications(_ name: String) {
        let body = description(.networkListener(TestData.listener("/tmp/\(name)"))).body
        #expect(isSingleLineWithoutFormatCharacters(body), "\(body)")
    }

    @Test(arguments: hostileNames)
    func autostartLabelIsSanitisedInNotifications(_ label: String) {
        let body = description(.autostartItem(TestData.item(label))).body
        #expect(isSingleLineWithoutFormatCharacters(body), "\(body)")
    }

    @Test(arguments: hostileNames)
    func mcpServerNameIsSanitisedInNotifications(_ name: String) {
        let body = description(.mcpServer(TestData.mcpServer(name))).body
        #expect(isSingleLineWithoutFormatCharacters(body), "\(body)")
    }

    @Test(arguments: hostileNames)
    func autoApprovalValueIsSanitisedInNotifications(_ value: String) {
        let body = description(.agentAutoApproval(TestData.autoApproval(value: value))).body
        #expect(isSingleLineWithoutFormatCharacters(body), "\(body)")
    }

    @Test func directConstructionSanitisesTitleAndBody() {
        let text = " \tÄnderung\r\n„größer“\u{202E}\u{200B}\u{0007}\u{00A0}→\u{2028}prüfen  "
        let description = ChangeDescription(title: text, body: text)
        #expect(description.title == "Änderung „größer“ → prüfen")
        #expect(description.body == "Änderung „größer“ → prüfen")
    }

    @Test(arguments: [0, 239, 240, 241, 1_000])
    func titleAndBodyHaveBoundedLength(_ length: Int) {
        let text = String(repeating: "e\u{301}", count: length)
        let description = ChangeDescription(title: text, body: text)
        let expected = length > 240 ? String(repeating: "e\u{301}", count: 239) + "…" : text
        #expect(description.title == expected)
        #expect(description.body == expected)
        #expect(description.title.count <= 240)
        #expect(description.body.count <= 240)
    }

    @Test func sanitisesBeforeApplyingLengthLimit() {
        let text = String(repeating: "\u{202E}\t\n", count: 300) + "Übersicht"
        let description = ChangeDescription(title: text, body: text)
        #expect(description.title == "Übersicht")
        #expect(description.body == "Übersicht")
    }

    @Test func summaryKeepsOnlyItsOwnLineBreaksAndBoundsEachEntry() {
        let events = ["a\n\u{202E}b", String(repeating: "x", count: 500), "third"].map { label in
            ChangeEvent(kind: .added, before: nil, after: .autostartItem(TestData.item(label)),
                        detectedAt: TestData.date)
        }
        let summary = ChangeDescription.summary(for: events)
        let lines = summary.body.components(separatedBy: "\n")
        #expect(summary.title == "3 Änderungen")
        #expect(lines.count == 3)
        #expect(lines.first == "Neuer Autostart-Eintrag: a b (LaunchAgent).")
        #expect(lines.last == "…")
        #expect(lines.allSatisfy { $0.count <= 240 && isSingleLineWithoutFormatCharacters($0) })
    }

    @Test func presentationPreservesOriginalEvent() throws {
        let label = "original\n\u{202E}label"
        let event = ChangeEvent(kind: .added, before: nil, after: .autostartItem(TestData.item(label)),
                                detectedAt: TestData.date)
        #expect(isSingleLineWithoutFormatCharacters(ChangeDescription(event).body))
        let restored = try JSONDecoder().decode(ChangeEvent.self, from: JSONEncoder().encode(event))
        #expect(restored == event)
        guard case .autostartItem(let item) = restored.subject else {
            Issue.record("Autostart-Ereignis erwartet")
            return
        }
        #expect(item.label == label)
    }

    /// Gegenprobe (heute korrekt): Programmname in Ablehnungen des Helpers ist bereinigt.
    @Test(arguments: hostileNames)
    func terminationMessagesAreAlreadySanitised(_ name: String) {
        #expect(isSingleLineWithoutFormatCharacters(ProcessTerminationPolicy.displayName(of: "/tmp/\(name)")))
    }
}
