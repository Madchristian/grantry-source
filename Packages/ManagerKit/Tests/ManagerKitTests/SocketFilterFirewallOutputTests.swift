import Testing
@testable import GrantryShared

/// Gemeinsame Auswertung für App (Anzeige) und Helper (Vorab-Abfrage). Fixtures: `Fixtures/Security`.
@Suite struct SocketFilterFirewallOutputTests {
    @Test(arguments: [
        ("socketfilterfw-on-stealth-on.txt", true, true), ("socketfilterfw-on-stealth-off.txt", true, false),
        ("socketfilterfw-off.txt", false, false), ("socketfilterfw-block-all.txt", true, true),
    ])
    func fixtures(fixture: String, enabled: Bool, stealth: Bool) throws {
        let output = try securityFixture(fixture)
        #expect(SocketFilterFirewallOutput.isEnabled(in: output) == enabled)
        #expect(SocketFilterFirewallOutput.isStealthModeOn(in: output) == stealth)
    }

    /// Der Helper liest `--getglobalstate` und `--getstealthmode` einzeln: Die jeweils andere Angabe fehlt.
    @Test func answersOnlyWhatTheOutputContains() {
        #expect(SocketFilterFirewallOutput.isEnabled(in: "Firewall is enabled. (State = 1)\n") == true)
        #expect(SocketFilterFirewallOutput.isStealthModeOn(in: "Firewall is enabled. (State = 1)\n") == nil)
        #expect(SocketFilterFirewallOutput.isStealthModeOn(in: "Firewall stealth mode is off\n") == false)
        #expect(SocketFilterFirewallOutput.isEnabled(in: "Firewall stealth mode is off\n") == nil)
    }

    /// Maßgeblich ist die Zahl: 0 aus, 1 an, 2 alle eingehenden blockieren – jeder Wert ≠ 0 gilt als an.
    @Test(arguments: [
        ("Firewall is disabled. (State = 0)", false),
        ("Firewall is enabled. (State = 1)", true),
        ("Firewall is enabled. (State = 2)", true),
        ("Firewall is enabled. (State = 1)\nFirewall has block all state set to enabled.", true),
        ("  Firewall is enabled. (State = 1)  \n\n", true),
    ] as [(String, Bool)])
    func globalStateIsTheNumber(output: String, enabled: Bool) {
        #expect(SocketFilterFirewallOutput.isEnabled(in: output) == enabled)
    }

    /// Unbekanntes Format → `nil` (der Helper bricht dann ab, die App meldet „nicht prüfbar“), nie eine Vermutung.
    @Test(arguments: [
        "", "Something new in macOS 28", "Firewall is enabled.", "Firewall is disabled.",
        "Firewall is enabled. (State = x)", "Other tool (State = 0)", "Firewall stealth mode is on",
    ])
    func unknownGlobalStateIsNil(output: String) {
        #expect(SocketFilterFirewallOutput.isEnabled(in: output) == nil)
    }

    @Test(arguments: ["", "Stealth?", "Firewall stealth mode is maybe", "Firewall is enabled. (State = 1)"])
    func unknownStealthModeIsNil(output: String) {
        #expect(SocketFilterFirewallOutput.isStealthModeOn(in: output) == nil)
    }

    @Test func toleratesSurroundingWhitespace() {
        #expect(SocketFilterFirewallOutput.isStealthModeOn(in: "  Firewall stealth mode is on \n") == true)
    }
}
