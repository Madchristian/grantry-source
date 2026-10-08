import Testing
@testable import GrantryShared

/// Gemeinsame Auswertung von `spctl --status` für App (Anzeige) und Helper (Vorab-Abfrage). Fixtures: `Fixtures/Security`.
@Suite struct GatekeeperStatusOutputTests {
    @Test(arguments: [("spctl-enabled.txt", true), ("spctl-disabled.txt", false)])
    func fixtures(fixture: String, enabled: Bool) throws {
        #expect(GatekeeperStatusOutput.isEnabled(in: try securityFixture(fixture)) == enabled)
    }

    /// Nur die bekannten Ausgaben zählen; alles andere ist unbekannt (`nil`) – nie eine Vermutung.
    @Test(arguments: [
        ("  assessments enabled  \n\n", true),
        ("assessments disabled", false),
        ("assessments maybe\n", nil),
        ("", nil),
        ("assessments enabled\nassessments disabled\n", nil),
    ] as [(String, Bool?)])
    func onlyKnownOutputsAreRecognized(_ output: String, enabled: Bool?) {
        #expect(GatekeeperStatusOutput.isEnabled(in: output) == enabled)
    }
}
