import Testing
import Foundation
@testable import ManagerKit

@Suite struct BTMParserTests {
    private func fixture(_ name: String = "btm-dump") throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func detectsSectionHeader() throws {
        #expect(BTMParser.containsSection(try fixture()))
        #expect(BTMParser.containsSection(" Records for UID 0 : X\r\n"))
        #expect(!BTMParser.containsSection(""))
        #expect(!BTMParser.containsSection("#1:\n Name: x"))
    }

    @Test func parsesAllRecords() throws {
        let records = BTMParser.parse(try fixture())
        #expect(records.map(\.name) == ["Docker", "com.docker.helper", "1Password Launcher", "de.cstrube.Grantry.Helper"])
    }

    @Test func parsesFieldsOfAppRecord() throws {
        let docker = try #require(BTMParser.parse(try fixture()).first)
        #expect(docker.type == .app)
        #expect(docker.isEnabled)
        #expect(docker.bundleID == "com.docker.docker")
        #expect(docker.teamID == "9BNSXJN65R")
        #expect(docker.url == "file:///Applications/Docker.app/")
        #expect(docker.executablePath == nil)
        #expect(docker.uid == 501)
    }

    @Test func mapsTypesAndDisposition() throws {
        let records = BTMParser.parse(try fixture())
        #expect(records.map(\.type) == [.app, .legacyDaemon, .loginItem, .daemon])
        #expect(records[2].isEnabled == false)
        #expect(records[3].executablePath == "/Applications/Grantry.app/Contents/MacOS/GrantryHelper")
        #expect(records[3].parentIdentifier == "2.de.cstrube.Grantry")
        #expect(records[3].parentBundleID == "de.cstrube.Grantry")
    }

    @Test func toleratesEmptyAndUnknownInput() {
        #expect(BTMParser.parse("").isEmpty)
        let odd = " #1:\n                 Name: X\n                 Type: something new (0x9999)\n      Future Field: y\n"
        #expect(BTMParser.parse(odd).first?.type == .other("something new"))
    }

    /// Eingebettete `#N: <id>`-Zeilen gehören zum laufenden Eintrag und beginnen keinen neuen.
    @Test func nestedNumberedLinesDoNotStartRecords() {
        let dump = """
         #1:
                         Name: Parent
                         Type: app (0x2)
            Embedded Item Identifiers:
                #1: 16.com.parent.helper
                #2: 4.com.parent.login
            Bundle Identifier: com.parent
        """
        let records = BTMParser.parse(dump)
        #expect(records.count == 1)
        #expect(records.first?.bundleID == "com.parent")
    }

    @Test func parsesRecordsOfAllUIDSectionsWithCRLF() {
        let dump = [
            "========================",
            " Records for UID 0 : 00000000-0000-0000-0000-000000000000",
            "========================",
            "",
            " Items:",
            "",
            " #1:",
            "                 Name: Root Item",
            "                 Type: daemon (0x10)",
            "          Disposition: [enabled, allowed] (0x3)",
            "",
            "========================",
            " Records for UID 501 : 7E4B2C1A-0000-4000-8000-000000000501",
            "========================",
            "",
            " #1:",
            "                 Name: User Item",
            "                 Type: agent (0x8)",
            "          Disposition: [disabled, allowed] (0x2)",
        ].joined(separator: "\r\n")
        let records = BTMParser.parse(dump)
        #expect(records.map(\.name) == ["Root Item", "User Item"])
        #expect(records.map(\.uid) == [0, 501])
        #expect(records.map(\.type) == [.daemon, .agent])
        #expect(records.map(\.isEnabled) == [true, false])
    }

    @Test func parentBundleIDRequiresNumericTypePrefix() {
        func record(parent: String?) -> BTMRecord {
            BTMRecord(name: "x", type: .agent, isEnabled: true, parentIdentifier: parent)
        }
        #expect(record(parent: "2.com.foo.bar").parentBundleID == "com.foo.bar")
        #expect(record(parent: "com.foo.bar").parentBundleID == nil)
        #expect(record(parent: "2.").parentBundleID == nil)
        #expect(record(parent: nil).parentBundleID == nil)
    }

    /// `(null)` steht bei `sfltool` für einen fehlenden Wert und darf nicht als URL, Team-ID usw. durchgehen.
    @Test func treatsNullValuesAsAbsent() throws {
        let dump = """
         #1:
                         Name: (null)
                         Type: developer (0x20)
                  Disposition: [disabled, allowed, not notified] (0x2)
                   Identifier: Unknown Developer
                          URL: (null)
        """
        let record = try #require(BTMParser.parse(dump).first)
        #expect(record.url == nil)
        #expect(record.name == "Unknown Developer")
    }

    /// `disallowed` heißt: in den Systemeinstellungen unter „Im Hintergrund erlauben“ ausgeschaltet – der Eintrag
    /// startet nicht, auch wenn die App ihn als `enabled` registriert hat.
    @Test func disallowedRecordIsNotEnabled() throws {
        let dump = """
         #1:
                         Name: WeatherMenu
                         Type: login item (0x4)
                  Disposition: [enabled, disallowed, notified] (0x9)
        """
        #expect(try #require(BTMParser.parse(dump).first).isEnabled == false)
    }

    @Test func unprefixedIdentifierDropsNumericTypePrefix() {
        func record(identifier: String?) -> BTMRecord {
            BTMRecord(name: "x", type: .agent, isEnabled: true, identifier: identifier)
        }
        #expect(record(identifier: "8.com.openai.chat-helper").unprefixedIdentifier == "com.openai.chat-helper")
        #expect(record(identifier: "Unknown Developer").unprefixedIdentifier == nil)
        #expect(record(identifier: nil).unprefixedIdentifier == nil)
    }
}

/// Echte Ausgabe von `sfltool dumpbtm` (macOS 27, anonymisiert: UUIDs, Benutzer- und Entwicklername).
@Suite struct BTMParserRealDumpTests {
    private let dump: String
    private let records: [BTMRecord]

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "btm-dump-real", withExtension: "txt", subdirectory: "Fixtures"))
        dump = try String(contentsOf: url, encoding: .utf8)
        records = BTMParser.parse(dump)
    }

    /// Jeder `#N:`-Block trägt genau eine `UUID:`-Zeile; eingebettete `#N: <id>`-Zeilen dürfen keine Einträge erzeugen.
    @Test func parsesRealDump() {
        let uuidLines = dump.split(whereSeparator: \.isNewline).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("UUID:") }
        #expect(!records.isEmpty)
        #expect(records.count == uuidLines.count)
        #expect(records.allSatisfy { !$0.name.isEmpty && $0.name != "(null)" })
        #expect(records.allSatisfy { $0.identifier != nil && $0.uid != nil })

        let types = Set(records.map { String(describing: $0.type) }).sorted()
        print("BTM-Typen im echten Dump: \(types.joined(separator: ", "))")
        #expect(Set(records.map(\.type)).isSuperset(of: [.app, .developer, .loginItem, .agent, .daemon, .legacyAgent, .legacyDaemon]))
        #expect(Set(records.map(\.type).filter { if case .other = $0 { true } else { false } }) == [
            .other("spotlight"), .other("quicklook"), .other("dock tile"),
            .other("background tasks"), .other("background app refresh"),
        ])
    }

    @Test func parsesAllUIDSectionsIncludingNegativeUID() {
        let counts = Dictionary(grouping: records, by: { $0.uid ?? .min }).mapValues(\.count)
        print("BTM-Einträge je UID: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        #expect(counts == [-2: 35, 0: 16, 82: 9, 501: 88])
    }

    /// `Parent Identifier` ist entweder `<typ>.<bundle-id>` eines App-Eintrags oder – bei Legacy-Plists – der Name
    /// eines `developer`-Eintrags; nur Ersteres ergibt eine Bundle-ID.
    @Test func parentIdentifiersPointToAppsOrDevelopers() {
        let appBundleIDs = Set(records.filter { $0.type == .app }.compactMap(\.bundleID))
        let developerIDs = Set(records.filter { $0.type == .developer }.compactMap(\.identifier))
        let children = records.filter { $0.parentIdentifier != nil }
        #expect(!children.isEmpty)
        for child in children {
            if let parent = child.parentBundleID {
                #expect(appBundleIDs.contains(parent), "\(child.name): \(parent)")
            } else {
                #expect(developerIDs.contains(child.parentIdentifier ?? ""), "\(child.name): \(child.parentIdentifier ?? "")")
            }
        }
    }

    @Test func readsFieldsOfEmbeddedDaemon() throws {
        let helper = try #require(records.first { $0.identifier == "16.de.cstrube.Grantry.Helper" })
        #expect(helper.type == .daemon && helper.uid == -2 && helper.isEnabled)
        #expect(helper.url == "Contents/Library/LaunchDaemons/de.cstrube.Grantry.Helper.plist")
        #expect(helper.executablePath == "Contents/MacOS/GrantryHelper")
        #expect(helper.parentBundleID == "de.cstrube.Grantry")
        #expect(helper.teamID == "73SP5UXC3Q")
    }

    @Test func disallowedItemsAreNotEnabled() {
        let disallowed = records.filter { !$0.isEnabled && $0.type != .app && $0.type != .developer }.compactMap(\.identifier)
        #expect(Set(disallowed).isSuperset(of: ["4.com.apple.weather.menu", "8.com.valvesoftware.steamclean"]))
    }
}
