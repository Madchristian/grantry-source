import Testing
import Foundation
@testable import ManagerKit

private struct FixtureDumpProvider: BTMDumpProviding {
    let output: String?
    func dumpBTM() async throws -> String {
        guard let output else { throw BTMSourceError.helperUnavailable }
        return output
    }
}

/// Wirft bei jedem Aufruf `error`.
private struct ThrowingDumpProvider: BTMDumpProviding {
    let error: any Error
    func dumpBTM() async throws -> String { throw error }
}

@Suite struct BTMSourceTests {
    private func fixture(_ name: String = "btm-dump") throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Ein `#N:`-Block im Format von `sfltool dumpbtm`.
    private func record(_ number: Int, name: String, type: String, parent: String? = nil, disposition: String = "enabled") -> String {
        var lines = [" #\(number):", "                 Name: \(name)", "                 Type: \(type)",
                     "          Disposition: [\(disposition), allowed] (0x3)"]
        if let parent { lines.append("    Parent Identifier: \(parent)") }
        return lines.joined(separator: "\n")
    }

    private func section(uid: Int, _ records: String...) -> String {
        (["========================", " Records for UID \(uid) : X", "========================", ""] + records)
            .joined(separator: "\n\n")
    }

    @Test func mapsRecordsAndSkipsLegacyAndAppEntries() async throws {
        let source = BTMSource(provider: FixtureDumpProvider(output: try fixture()), resolver: StubAppResolver())
        let items = try await source.collect().autostartItems

        #expect(source.id == .btm)
        #expect(items.map(\.label) == ["com.1password.1password-launcher", "de.cstrube.Grantry.Helper"])

        let launcher = items[0]
        #expect(launcher.kind == .loginItem && launcher.domain == .user && launcher.source == .btm)
        #expect(!launcher.isEnabled)
        #expect(launcher.isLoaded == nil)
        #expect(launcher.plistPath == nil)
        #expect(launcher.program == "/Applications/1Password.app/Contents/Library/LoginItems/1Password Launcher.app")
        #expect(launcher.owner?.bundleID == "com.1password.1password")

        let helper = items[1]
        #expect(helper.kind == .backgroundTask && helper.domain == .system)
        #expect(helper.isEnabled)
        #expect(helper.program == "/Applications/Grantry.app/Contents/MacOS/GrantryHelper")
        #expect(helper.owner?.bundleID == "de.cstrube.Grantry")
    }

    @Test func mapsAgentsAndSkipsDeveloperAndUnknownTypes() async throws {
        let dump = section(uid: 501,
                           record(1, name: "com.example.agent", type: "agent (0x8)"),
                           record(2, name: "dev", type: "developer (0x20)"),
                           record(3, name: "future", type: "quantum item (0x9999)"),
                           record(4, name: "legacy", type: "legacy agent (0x10008)"))
        let items = try await BTMSource(provider: FixtureDumpProvider(output: dump), resolver: StubAppResolver())
            .collect().autostartItems

        #expect(items.map(\.label) == ["com.example.agent"])
        #expect(items[0].kind == .backgroundTask && items[0].domain == .user)
        #expect(items[0].owner == nil)
        #expect(items[0].program == nil && items[0].programPresence == .unknown)
    }

    @Test func resolvesEachOwnerOncePerCollect() async throws {
        let dump = section(uid: 501,
                           record(1, name: "a", type: "agent (0x8)", parent: "2.com.example.app"),
                           record(2, name: "b", type: "daemon (0x10)", parent: "2.com.example.app"),
                           record(3, name: "c", type: "agent (0x8)", parent: "2.com.other.app"))
        let resolver = CountingResolver()
        let items = try await BTMSource(provider: FixtureDumpProvider(output: dump), resolver: resolver)
            .collect().autostartItems

        #expect(items.map(\.owner?.bundleID) == ["com.example.app", "com.example.app", "com.other.app"])
        #expect(resolver.calls == 2)
    }

    /// Derselbe Eintrag unter mehreren UIDs ergäbe doppelte IDs; kommt `preferredUID` in keinem der Abschnitte vor,
    /// gewinnt der erste im Dump.
    @Test func deduplicatesItemsWithSameIDAcrossUIDSections() async throws {
        let dump = section(uid: 0, record(1, name: "com.example.agent", type: "agent (0x8)", disposition: "disabled"))
            + "\n" + section(uid: 501,
                             record(1, name: "com.example.agent", type: "agent (0x8)"),
                             record(2, name: "com.example.agent", type: "daemon (0x10)"))
        let items = try await BTMSource(provider: FixtureDumpProvider(output: dump), resolver: StubAppResolver(), preferredUID: 999)
            .collect().autostartItems

        #expect(items.map(\.id) == ["backgroundTask|user|com.example.agent", "backgroundTask|system|com.example.agent"])
        #expect(items[0].isEnabled == false)
    }

    /// Kommt `preferredUID` in einem der Abschnitte vor, gewinnt dessen Eintrag – unabhängig von der Reihenfolge der
    /// Abschnitte im Dump.
    @Test(arguments: [true, false])
    func prefersRecordsOfConsoleUser(uid501First: Bool) async throws {
        let uid0Section = section(uid: 0, record(1, name: "com.example.launcher", type: "login item (0x4)", disposition: "disabled"))
        let uid501Section = section(uid: 501, record(1, name: "com.example.launcher", type: "login item (0x4)", disposition: "enabled"))
        let dump = uid501First ? uid501Section + "\n" + uid0Section : uid0Section + "\n" + uid501Section

        let items = try await BTMSource(provider: FixtureDumpProvider(output: dump), resolver: StubAppResolver(), preferredUID: 501)
            .collect().autostartItems

        #expect(items.map(\.id) == ["loginItem|user|com.example.launcher"])
        #expect(items[0].isEnabled == true)
    }

    /// Enthält der bevorzugte Abschnitt selbst mehrere Treffer für dieselbe ID, gewinnt der erste von ihnen –
    /// ein späterer Treffer aus demselben Abschnitt darf ihn nicht wieder verdrängen.
    @Test func firstPreferredDuplicateWinsOverLaterPreferredDuplicates() async throws {
        let dump = section(uid: 0, record(1, name: "com.example.agent", type: "agent (0x8)", disposition: "disabled"))
            + "\n" + section(uid: 501, record(2, name: "com.example.agent", type: "agent (0x8)", disposition: "enabled"))
            + "\n" + section(uid: 0, record(3, name: "com.example.agent", type: "agent (0x8)", disposition: "disabled"))
            + "\n" + section(uid: 501, record(4, name: "com.example.agent", type: "agent (0x8)", disposition: "disabled"))
        let items = try await BTMSource(provider: FixtureDumpProvider(output: dump), resolver: StubAppResolver(), preferredUID: 501)
            .collect().autostartItems

        #expect(items.map(\.id) == ["backgroundTask|user|com.example.agent"])
        #expect(items[0].isEnabled == true)
    }

    /// Ein echter Dump hat immer einen `Records for UID`-Kopf; ohne ihn wären alle Einträge scheinbar gelöscht.
    @Test(arguments: ["", "   \n", "sfltool: command not found", "#1:\n Name: orphan\n Type: agent (0x8)"])
    func dumpWithoutSectionHeaderIsUnparseable(dump: String) async {
        let source = BTMSource(provider: FixtureDumpProvider(output: dump), resolver: StubAppResolver())
        await #expect(throws: BTMSourceError.unparseableDump) { try await source.collect() }
    }

    @Test func dumpWithHeaderButNoRecordsYieldsNoItems() async throws {
        let source = BTMSource(provider: FixtureDumpProvider(output: section(uid: 501)), resolver: StubAppResolver())
        #expect(try await source.collect().autostartItems.isEmpty)
    }

    @Test func propagatesProviderFailure() async {
        let source = BTMSource(provider: FixtureDumpProvider(output: nil), resolver: StubAppResolver())
        await #expect(throws: BTMSourceError.helperUnavailable) { try await source.collect() }
    }

    @Test func passesCancellationThrough() async {
        let source = BTMSource(provider: ThrowingDumpProvider(error: CancellationError()), resolver: StubAppResolver())
        await #expect(throws: CancellationError.self) { try await source.collect() }
    }

    /// Im echten Format sind `URL` und `Executable Path` eingebetteter Einträge relativ zum Bundle der Eltern-App,
    /// deren `URL` ein schlichter absoluter Pfad ist.
    @Test func resolvesBundleRelativePathsAgainstParentApp() async throws {
        let dump = section(uid: 501, """
         #1:
                         Name: Docker
                         Type: app (0x2)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: 2.com.docker.docker
                          URL: /Applications/Docker.app
            Bundle Identifier: com.docker.docker
        """, """
         #2:
                         Name: DockerHelper
                         Type: login item (0x4)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 4.com.docker.helper
                          URL: Contents/Library/LoginItems/DockerHelper.app
            Bundle Identifier: com.docker.helper
            Parent Identifier: 2.com.docker.docker
        """, """
         #3:
                         Name: ChatGPTHelper
                         Type: agent (0x8)
                  Disposition: [enabled, allowed, notified] (0xb)
                   Identifier: 8.com.openai.chat-helper
                          URL: Contents/Library/LaunchAgents/com.openai.chat-helper.plist
              Executable Path: Contents/Resources/ChatGPTHelper
            Parent Identifier: 2.com.openai.chat
        """)
        let items = try await BTMSource(provider: FixtureDumpProvider(output: dump), resolver: StubAppResolver())
            .collect().autostartItems

        #expect(items.map(\.program) == [
            "/Applications/Docker.app/Contents/Library/LoginItems/DockerHelper.app",
            // Eltern-App fehlt im Dump: Pfad der aufgelösten Eigentümer-App.
            "/Applications/com.openai.chat.app/Contents/Resources/ChatGPTHelper",
        ])
    }

    /// Ohne bekannte Basis bleibt ein relativer Pfad unbekannt (`nil`) – sonst wäre er ein vermeintlich verwaister Pfad.
    @Test func relativePathWithoutParentIsUnknown() async throws {
        let dump = section(uid: 501, """
         #1:
                         Name: Helper
                         Type: agent (0x8)
                  Disposition: [enabled, allowed] (0x3)
              Executable Path: Contents/MacOS/Helper
        """)
        let items = try await BTMSource(provider: FixtureDumpProvider(output: dump), resolver: StubAppResolver())
            .collect().autostartItems
        #expect(items.map(\.program) == [nil])
    }

    /// Ohne Bundle-ID ist das Label die Kennung ohne Typ-Präfix (das launchd-Label), nicht der Anzeigename.
    @Test func labelFallsBackToUnprefixedIdentifier() async throws {
        let dump = section(uid: 501, """
         #1:
                         Name: ChatGPTHelper
                         Type: agent (0x8)
                  Disposition: [enabled, allowed] (0x3)
                   Identifier: 8.com.openai.chat-helper
        """)
        let items = try await BTMSource(provider: FixtureDumpProvider(output: dump), resolver: StubAppResolver())
            .collect().autostartItems
        #expect(items.map(\.label) == ["com.openai.chat-helper"])
    }

    @Test func mapsRealDump() async throws {
        let items = try await BTMSource(
            provider: FixtureDumpProvider(output: try fixture("btm-dump-real")), resolver: StubAppResolver(), preferredUID: 501
        ).collect().autostartItems

        for item in items {
            print("BTM-Item \(item.id) enabled=\(item.isEnabled) program=\(item.program ?? "-") owner=\(item.owner?.bundleID ?? "-")")
        }
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items.map(\.id) == [
            "backgroundTask|system|de.cstrube.Grantry.Helper",
            "backgroundTask|user|com.openai.chat-helper",
            "loginItem|user|com.docker.helper",
            "loginItem|user|com.microsoft.OneDriveLauncher",
            "loginItem|user|com.apple.Passwords.MenuBarExtra",
            "loginItem|user|io.tailscale.ipn.macos.login-item-helper",
            "loginItem|user|com.apple.weather.menu",
            "loginItem|user|com.wireguard.macos.login-item-helper",
        ])
        #expect(items.allSatisfy { $0.program?.hasPrefix("/") == true && $0.owner != nil })
        #expect(items.first?.program == "/Applications/Grantry.app/Contents/MacOS/GrantryHelper")
        #expect(items[1].program == "/Applications/ChatGPT Classic.app/Contents/Resources/ChatGPTHelper")
        #expect(items[4].program == "/System/Applications/Passwords.app/Contents/Library/LoginItems/PasswordsMenuBarExtra.app")
        #expect(items.filter(\.isEnabled).count == 5)
    }
}
