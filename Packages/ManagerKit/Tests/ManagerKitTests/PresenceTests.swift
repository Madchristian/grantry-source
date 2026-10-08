import Foundation
import Testing
@testable import ManagerKit
import TestSupport

@Suite struct PresenceTests {
    @Test func existingFileIsPresent() {
        #expect(Presence(ofItemAt: "/bin/ls") == .present)
    }

    @Test func missingFileIsMissing() {
        #expect(Presence(ofItemAt: "/opt/does-not-exist-\(UUID())/tool") == .missing)
    }

    /// Ein Pfadbestandteil ist eine Datei statt eines Verzeichnisses (`ENOTDIR`) – das Ziel kann nicht existieren.
    @Test func fileBelowRegularFileIsMissing() {
        #expect(Presence(ofItemAt: "/bin/ls/tool") == .missing)
    }

    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte")) func fileInsideUnreadableDirectoryIsUnknown() async throws {
        try await LockedDirectoryFixture.with(fileNamed: "wazuh-modulesd") { file in
            #expect(Presence(ofItemAt: file.path) == .unknown)
        }
    }

    @Test func danglingSymlinkIsMissing() throws {
        try ScratchDirectory.with(prefix: "presence") { directory in
            let link = directory.appending(path: "tool")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appending(path: "gone"))
            #expect(Presence(ofItemAt: link.path) == .missing)
        }
    }

    /// Vor der Umstellung auf `Presence` gespeicherte Snapshots kennen nur `exists` bzw. `programExists`.
    @Test func appIdentityDecodesLegacyExistsFlag() throws {
        func decode(_ exists: Bool) throws -> Presence {
            let json = #"{"displayName":"X","signing":{"kind":"unknown","isNotarized":false},"exists":\#(exists)}"#
            return try JSONDecoder().decode(AppIdentity.self, from: Data(json.utf8)).presence
        }
        #expect(try decode(true) == .present)
        #expect(try decode(false) == .missing)
    }

    @Test func autostartItemDecodesLegacyProgramExistsFlag() throws {
        func decode(program: String?, exists: Bool) throws -> Presence {
            let programJSON = program.map { #""program":"\#($0)","# } ?? ""
            let json = #"{"kind":"launchDaemon","domain":"system","label":"x",\#(programJSON)"programExists":\#(exists),"isEnabled":true,"source":"launchd"}"#
            return try JSONDecoder().decode(AutostartItem.self, from: Data(json.utf8)).programPresence
        }
        #expect(try decode(program: "/opt/x", exists: true) == .present)
        #expect(try decode(program: "/opt/x", exists: false) == .missing)
        // Ohne Programmpfad hieß `false` schon bisher „unbekannt“, nicht „fehlt“.
        #expect(try decode(program: nil, exists: false) == .unknown)
    }

    @Test func presenceRoundTripsThroughJSON() throws {
        let app = TestData.app(presence: .probablyMissing)
        let item = TestData.item(programPresence: .unknown)
        #expect(try JSONDecoder().decode(AppIdentity.self, from: JSONEncoder().encode(app)) == app)
        #expect(try JSONDecoder().decode(AutostartItem.self, from: JSONEncoder().encode(item)) == item)
    }
}
