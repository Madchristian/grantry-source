import Foundation
import Testing
@testable import ManagerKit

private func securityFixtureURL(_ name: String) throws -> URL {
    let file = URL(fileURLWithPath: name)
    return try #require(Bundle.module.url(
        forResource: file.deletingPathExtension().lastPathComponent, withExtension: file.pathExtension,
        subdirectory: "Fixtures/Security"
    ))
}

func securityFixture(_ name: String) throws -> String {
    try String(contentsOf: securityFixtureURL(name), encoding: .utf8)
}

func securityFixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: securityFixtureURL(name))
}

@Suite struct SecurityParsersTests {
    @Test(arguments: [
        ("fdesetup-on.txt", FileVaultStatus.on), ("fdesetup-off.txt", .off), ("fdesetup-encrypting.txt", .encrypting),
        ("fdesetup-decrypting.txt", .decrypting), ("fdesetup-deferred.txt", .pendingRestart),
    ])
    func fileVault(fixture: String, expected: FileVaultStatus) throws {
        #expect(try SecurityParsers.fileVault(securityFixture(fixture)) == .fileVault(expected))
    }

    @Test(arguments: [
        ("socketfilterfw-on-stealth-on.txt", true, true), ("socketfilterfw-on-stealth-off.txt", true, false),
        ("socketfilterfw-off.txt", false, false), ("socketfilterfw-block-all.txt", true, true),
    ])
    func firewall(fixture: String, enabled: Bool, stealth: Bool) throws {
        #expect(try SecurityParsers.firewall(securityFixture(fixture)) == .firewall(enabled: enabled, stealthMode: stealth))
    }

    @Test(arguments: [
        ("csrutil-enabled.txt", SIPStatus.enabled), ("csrutil-disabled.txt", .disabled),
        ("csrutil-custom.txt", .customConfiguration),
    ])
    func sip(fixture: String, expected: SIPStatus) throws {
        #expect(try SecurityParsers.sip(securityFixture(fixture)) == .sip(expected))
    }

    @Test func gatekeeper() throws {
        #expect(try SecurityParsers.gatekeeper(securityFixture("spctl-enabled.txt")) == .gatekeeper(enabled: true))
        #expect(try SecurityParsers.gatekeeper(securityFixture("spctl-disabled.txt")) == .gatekeeper(enabled: false))
    }

    @Test func xprotectFromJSON() throws {
        let installedAt = try Date("2026-09-29T20:53:25Z", strategy: .iso8601)
        #expect(try SecurityParsers.xprotect(securityFixture("xprotect-version.json")) == .xprotect(version: "5363", installedAt: installedAt))
    }

    @Test func mdmEnrollment() throws {
        #expect(try SecurityParsers.mdmEnrollment(securityFixture("profiles-not-enrolled.txt")) == .mdmEnrollment(enrolled: false, viaDEP: false))
        #expect(try SecurityParsers.mdmEnrollment(securityFixture("profiles-enrolled.txt")) == .mdmEnrollment(enrolled: true, viaDEP: true))
    }

    @Test(arguments: ["", "Something new in macOS 28", "Firewall is enabled. (State = 1)"])
    func unknownOutputThrowsReadableError(output: String) {
        #expect(throws: SecurityParseError.self) { try SecurityParsers.firewall(output) }
        #expect(throws: SecurityParseError.self) { try SecurityParsers.fileVault(output) }
    }

    /// Nur „Yes…“ und „No“ sind bekannt; ein neuer Wert (etwa „Pending“) darf keine Abmeldung vortäuschen.
    @Test(arguments: [
        "Enrolled via DEP: No\nMDM enrollment: Pending",
        "Enrolled via DEP: Pending\nMDM enrollment: No",
        "Enrolled via DEP: No\nMDM enrollment: ",
    ])
    func unknownEnrollmentValueThrows(output: String) {
        #expect(throws: SecurityParseError.self) { try SecurityParsers.mdmEnrollment(output) }
    }

    @Test func xprotectTextOutputIsRejected() throws {
        // Absicherung: der Probe muss `--json` übergeben.
        #expect(throws: SecurityParseError.self) { try SecurityParsers.xprotect(securityFixture("xprotect-version.txt")) }
    }

    @Test func parseErrorNamesCommandAndExcerpt() {
        let error = SecurityParseError.unexpectedOutput(command: "spctl --status", output: "  assessments maybe \n")
        #expect(error.readableDescription == "Unerwartete Ausgabe von spctl --status: „assessments maybe“")
        #expect(SecurityParseError.unexpectedOutput(command: "spctl --status", output: "").readableDescription
            == "Unerwartete Ausgabe von spctl --status: (leer)")
    }
}

@Suite struct SoftwareUpdatePreferencesTests {
    /// Fixture als Wörterbuch, verändert und wieder als Plist-Daten.
    private func variant(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var plist = try #require(
            try PropertyListSerialization.propertyList(from: securityFixtureData("SoftwareUpdate.plist"), format: nil) as? [String: Any]
        )
        change(&plist)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    @Test func realPlist() throws {
        let preferences = try SoftwareUpdatePreferences(data: securityFixtureData("SoftwareUpdate.plist"))
        #expect(preferences.disabledKeys.isEmpty)  // AutomaticCheckEnabled fehlt → Standard an
        // Neuester der vier Erfolgsstempel: `LastSuccessfulMSUScanDate` (15:47:24) vor `LastSuccessfulDate` (15:47:12).
        #expect(preferences.lastSuccessfulCheck == (try Date("2026-09-30T15:47:24Z", strategy: .iso8601)))
        #expect(preferences.recommendedUpdates.map(\.identifier) == ["MSU_UPDATE_26A434_patch_27.0.1_minor", "ProVideoFormats"])
        // Apple liefert den Namen mit geschütztem Leerzeichen; er wird unverändert übernommen.
        #expect(preferences.recommendedUpdates[0].displayName == "macOS\u{00A0}27.0.1")
        #expect(preferences.recommendedUpdates[0].firstOfferedAt == (try Date("2026-09-28T22:41:56Z", strategy: .iso8601)))
        #expect(preferences.recommendedUpdates[1].displayVersion == "3.2")
        #expect(preferences.recommendedUpdates[1].firstOfferedAt == nil)
    }

    @Test func explicitFalseKeysAreDisabled() throws {
        let data = try variant {
            $0["AutomaticCheckEnabled"] = false
            $0["AutomaticallyInstallMacOSUpdates"] = false
        }
        #expect(try SoftwareUpdatePreferences(data: data).disabledKeys == [.automaticCheckEnabled, .automaticallyInstallMacOSUpdates])
    }

    @Test func missingKeysAndListsAreDefaults() throws {
        let data = try variant { plist in
            for key in SoftwareUpdateKey.allCases { plist.removeValue(forKey: key.rawValue) }
            plist.removeValue(forKey: "RecommendedUpdates")
            for key in Self.successKeys { plist.removeValue(forKey: key) }
        }
        let preferences = try SoftwareUpdatePreferences(data: data)
        #expect(preferences.disabledKeys.isEmpty)
        #expect(preferences.recommendedUpdates.isEmpty)
        #expect(preferences.lastSuccessfulCheck == nil)
    }

    private static let successKeys = [
        "LastSuccessfulDate", "LastFullSuccessfulDate", "LastBackgroundSuccessfulDate", "LastSuccessfulMSUScanDate",
    ]

    /// Jeder der vier Erfolgsstempel zählt, auch allein; maßgeblich ist der neueste. Beleg: `softwareupdate --list` als
    /// Nutzer aktualisierte nur `LastSuccessfulMSUScanDate`.
    @Test(arguments: successKeys)
    func newestSuccessStampWins(key: String) throws {
        let newest = try Date("2026-10-02T08:00:00Z", strategy: .iso8601)
        let data = try variant { $0[key] = newest }
        #expect(try SoftwareUpdatePreferences(data: data).lastSuccessfulCheck == newest)
        let alone = try variant { plist in
            for other in Self.successKeys where other != key { plist.removeValue(forKey: other) }
        }
        let fixtureDate = try #require(
            try PropertyListSerialization.propertyList(from: securityFixtureData("SoftwareUpdate.plist"), format: nil)
                as? [String: Any]
        )[key] as? Date
        #expect(try SoftwareUpdatePreferences(data: alone).lastSuccessfulCheck == fixtureDate)
    }

    /// Ein Stempel, der kein Datum ist, wird übergangen.
    @Test func nonDateSuccessStampIsIgnored() throws {
        let data = try variant { $0["LastSuccessfulMSUScanDate"] = "kein Datum" }
        #expect(try SoftwareUpdatePreferences(data: data).lastSuccessfulCheck
            == (try Date("2026-09-30T15:47:21Z", strategy: .iso8601)))
    }

    /// Ein kaputter Eintrag in `FirstOfferDateDictionary` verwirft nicht die übrigen Angebotsdaten.
    @Test func brokenOfferDateKeepsTheOthers() throws {
        let data = try variant { plist in
            var offers = plist["FirstOfferDateDictionary"] as? [String: Any] ?? [:]
            offers["093-49976"] = "kein Datum"
            plist["FirstOfferDateDictionary"] = offers
        }
        let preferences = try SoftwareUpdatePreferences(data: data)
        #expect(preferences.recommendedUpdates[0].firstOfferedAt == (try Date("2026-09-28T22:41:56Z", strategy: .iso8601)))
        #expect(preferences.recommendedUpdates[1].firstOfferedAt == nil)
    }

    @Test func garbageThrows() {
        #expect(throws: SecurityParseError.unreadablePreferences(path: SecurityTools.softwareUpdatePreferences)) {
            try SoftwareUpdatePreferences(data: Data("kein plist".utf8))
        }
    }
}
