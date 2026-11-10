import Foundation
import Testing
@testable import ManagerKit

/// Fixtures aus `systemextensionsctl list` (ohne Root). „endpoint-security-versions“ und „driver-active“ sind echte
/// Ausgaben (macOS 27.2); die übrigen folgen demselben Format (Tabulatoren, Abschnittsköpfe) für Zustände, die auf
/// dem Mess-Mac nicht vorkamen.
@Suite struct SystemExtensionListParserTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/Extensions")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func noExtensionsIsCompleteAndEmpty() throws {
        let list = try SystemExtensionListParser.parse(fixture("systemextensions-none"))
        #expect(list.extensions.isEmpty)
        #expect(list.declaredCount == 0)
        #expect(list.isComplete)
    }

    @Test func activeDriver() throws {
        let list = try SystemExtensionListParser.parse(fixture("systemextensions-driver-active"))
        #expect(list.isComplete)
        #expect(list.extensions == [
            SystemExtension(
                category: .driver, isEnabled: true, isActive: true, teamID: "Y93VXCB8Q5",
                bundleID: "com.corsair.cue.main.VirtualHIDDeviceDriver", version: "1.8.10", buildVersion: "1.8.10",
                name: "com.corsair.cue.main.VirtualHIDDeviceDriver", state: .activatedEnabled
            ),
        ])
    }

    /// Endpoint Security mit mehreren Versionen derselben Bundle-ID: Jede Zeile bleibt ein eigener Eintrag, die alten
    /// warten auf den Neustart.
    @Test func endpointSecurityWithSeveralVersions() throws {
        let list = try SystemExtensionListParser.parse(fixture("systemextensions-endpoint-security-versions"))
        #expect(list.isComplete)
        #expect(list.declaredCount == 5)
        let security = list.extensions.filter { $0.category == .endpointSecurity }
        #expect(security.count == 4)
        #expect(Set(security.map(\.bundleID)) == ["com.microsoft.wdav.epsext"])
        #expect(security.map(\.version) == ["101.26072.0017", "101.26092.0009", "101.26092.0012", "101.26082.0012"])
        let waiting = security.filter { $0.state == .terminatedWaitingToUninstallOnReboot }
        #expect(waiting.count == 3)
        #expect(waiting.allSatisfy { !$0.isEnabled && !$0.isActive })
        let current = try #require(security.first { $0.state == .activatedEnabled })
        #expect(current.isEnabled && current.isActive)
        #expect(current.name == "Microsoft Defender Endpoint Security Extension")
        #expect(current.teamID == "UBF8T346G9")
    }

    @Test func activatedWaitingForUser() throws {
        let list = try SystemExtensionListParser.parse(fixture("systemextensions-waiting-for-user"))
        let entry = try #require(list.extensions.first)
        #expect(entry.category == .network)
        #expect(entry.state == .activatedWaitingForUser)
        #expect(entry.isEnabled && !entry.isActive)
        #expect(entry.name == "LuLu")
    }

    @Test func networkAndCameraExtensions() throws {
        let list = try SystemExtensionListParser.parse(fixture("systemextensions-network-camera"))
        #expect(list.isComplete)
        #expect(list.extensions.map(\.category) == [.network, .network, .camera])
        #expect(list.extensions.map(\.state) == [.activatedEnabled, .activatedDisabled, .activatedEnabled])
        #expect(list.extensions[0].version == "6.2.1")
        #expect(list.extensions[0].buildVersion == "6224")
        #expect(list.extensions[2].name == "Camo Camera")
    }

    /// Unbekannte Kategorien und Zustände bleiben als solche erhalten; fremde Namen kommen einzeilig und gekürzt an.
    @Test func specialNamesUnknownKindsAndBrokenLines() throws {
        let list = try SystemExtensionListParser.parse(fixture("systemextensions-special-names"))
        #expect(list.unreadableLineCount == 1)
        #expect(!list.isComplete)
        let byID = Dictionary(list.extensions.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byID["de.example.treiber"]?.name == "Grüße – Treiber ☕︎ (Beta)")
        #expect(byID["de.example.bidi"]?.name == "AppleSystem Treiber")
        let long = try #require(byID["de.example.long"]?.name)
        #expect(long.count == ExtensionText.maximumNameLength)
        #expect(long.hasSuffix("…"))
        let future = try #require(byID["de.example.future"])
        #expect(future.category == .unknown("com.apple.system_extension.future_kind"))
        #expect(future.state == .unknown("validating by category"))
        #expect(future.teamID == nil)
        #expect(byID["de.example.tabname"]?.name == "Name mit Tab")
    }

    /// Ohne Kopfzeile ist das Format unbekannt: Eine leere Liste würde sonst alle bekannten Erweiterungen scheinbar
    /// entfernen.
    @Test(arguments: ["", "Error: something went wrong\n", "systemextensionsctl: unknown command\n"])
    func unknownFormatThrows(_ output: String) {
        #expect(throws: SystemExtensionListParser.FormatError.self) {
            try SystemExtensionListParser.parse(output)
        }
    }

    /// Kopfzahl und gelesene Einträge passen nicht zusammen → unvollständig, auch ohne kaputte Zeile.
    @Test func declaredCountMismatchIsIncomplete() throws {
        let output = try fixture("systemextensions-driver-active").replacingOccurrences(of: "1 extension(s)", with: "2 extension(s)")
        let list = try SystemExtensionListParser.parse(output)
        #expect(list.unreadableLineCount == 0)
        #expect(!list.isComplete)
    }

    /// Einträge vor dem ersten Abschnittskopf haben keine Kategorie und zählen als nicht lesbar.
    @Test func rowBeforeSectionIsUnreadable() throws {
        let output = "1 extension(s)\n*\t*\tTEAM\tde.example (1/1)\tName\t[activated enabled]\n"
        let list = try SystemExtensionListParser.parse(output)
        #expect(list.extensions.isEmpty)
        #expect(list.unreadableLineCount == 1)
    }

    @Test func versionWithoutBuildPart() throws {
        let output = "1 extension(s)\n--- com.apple.system_extension.driver_extension\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n"
            + "*\t*\tTEAM\tde.example.driver (2.0)\tTreiber\t[activated enabled]\n"
        let entry = try #require(try SystemExtensionListParser.parse(output).extensions.first)
        #expect(entry.version == "2.0")
        #expect(entry.buildVersion == nil)
    }
}
