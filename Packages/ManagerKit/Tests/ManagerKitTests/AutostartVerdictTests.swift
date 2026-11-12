import Foundation
import Testing
@testable import ManagerKit

/// Zustandszeile im Bereich Autostart (LB-2.3, #540; Spec 2026-11-10 § 11.2 a): „N Einträge auffällig“, sonst „Ruhig“;
/// dritter Chip „N deaktiviert“, wenn Platz bleibt; zählt über alle Einträge, unabhängig von Suche und Filter.
@Suite struct AutostartVerdictTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ label: String, enabled: Bool = true) -> AutostartItem {
        AutostartItem(kind: .launchAgent, domain: .user, label: label, program: "/usr/local/bin/\(label)",
                      programPresence: .present, isEnabled: enabled, isLoaded: nil,
                      plistPath: "/Library/LaunchAgents/\(label).plist", owner: nil, source: .launchd)
    }

    private func badges(_ findings: [RiskFinding]) -> RecordBadges {
        RecordBadges(findings: findings, events: [], cleanupHints: [], now: now)
    }

    @Test func countsConspicuousEntriesAndDisabledAsThirdChip() {
        let updater = item("com.example.updater")
        let vpn = item("com.example.vpn")
        let items = [updater, vpn, item("com.example.old", enabled: false), item("com.example.meeting", enabled: false)]
        let verdict = InventoryVerdict.autostart(items, badges: badges([
            RiskFinding(rule: .orphan, severity: .medium, recordID: updater.id, message: ""),
            RiskFinding(rule: .orphan, severity: .medium, recordID: vpn.id, message: ""),
        ]), missingSources: 0)
        #expect(verdict.title == "2 Einträge auffällig")
        #expect(verdict.isFinding)
        #expect(verdict.items == [SystemVerdict.Item(text: "2 prüfen", tone: .warning),
                                  SystemVerdict.Item(text: "2 deaktiviert", tone: .neutral)])
    }

    @Test func calmWithoutDisabledHasNoChips() {
        let verdict = InventoryVerdict.autostart([item("com.example.a")], badges: badges([]), missingSources: 0)
        #expect(verdict.title == "Ruhig")
        #expect(verdict.items.isEmpty)
    }

    /// Fehlende Quellen: keine Entwarnung.
    @Test func missingSourcesAreNoAllClear() {
        let verdict = InventoryVerdict.autostart([item("com.example.a")], badges: badges([]), missingSources: 1)
        #expect(verdict.title == "Nicht vollständig geprüft")
        #expect(verdict.items.first == SystemVerdict.Item(text: "1 Quelle fehlt", tone: .warning))
    }
}
