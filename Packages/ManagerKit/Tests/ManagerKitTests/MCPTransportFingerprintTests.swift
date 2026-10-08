import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// #137, Codex Runde 8: Seit Skripte hinter `sh -c` ganz verborgen werden, unterscheidet sich der maskierte Transport
/// zweier Skripte nicht mehr. Der Fingerabdruck der Rohwerte (wie bei Autostart) hält die Änderung im Verlauf, in
/// Benachrichtigungen und im Inhalts-Stempel.
@Suite struct MCPTransportFingerprintTests {
    private let later = TestData.date.addingTimeInterval(60)

    private static func config(_ script: String) -> String {
        #"{"mcpServers": {"s": {"command": "sh", "args": ["-c", "\#(script)"]}}}"#
    }

    private func server(_ script: String, fingerprinter: SecretFingerprinter = .processLocal) throws -> MCPServerEntry {
        let tool = try #require(AgentToolCatalog.standard.tool(id: "claudeDesktop"))
        let file = tool.files[0]
        let document = try ConfigParsing.parse(Data(Self.config(script).utf8), syntax: .json, redaction: file.redaction)
        let extraction = AgentConfigExtractor.extract(document, file: file, tool: tool, configPath: "/h/config.json",
                                                      fingerprinter: fingerprinter)
        return try #require(extraction.servers.first)
    }

    private func snapshot(_ server: MCPServerEntry, at date: Date = TestData.date) -> Snapshot {
        Snapshot(takenAt: date, grants: [], autostartItems: [], mcpServers: [server], sourceErrors: [],
                 baselineSources: TestData.allSources)
    }

    private func events(from old: MCPServerEntry, to new: MCPServerEntry) -> [ChangeEvent] {
        SnapshotDiffer().diff(from: snapshot(old), to: snapshot(new, at: later))
    }

    @Test func changeOfAHiddenScriptIsReported() throws {
        let old = try server("node serverA.js --token abc")
        let new = try server("node serverB.js --token abc")
        #expect(old.transport == .local(command: "sh", arguments: ["-c", "•••"]))
        #expect(old.transport == new.transport)

        let event = try #require(events(from: old, to: new).first)
        #expect(event.kind == .modified)
        #expect(ChangeDescription(event).body.contains("maskierte Zugangsdaten im Befehl geändert"))
        #expect(!snapshot(old).isEquivalent(to: snapshot(new)))
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("serverA") && !encoded.contains("serverB") && !encoded.contains("abc"))
    }

    @Test func unchangedHiddenScriptIsQuiet() throws {
        let old = try server("node serverA.js --token abc")
        #expect(events(from: old, to: try server("node serverA.js --token abc")).isEmpty)
        #expect(snapshot(old).isEquivalent(to: snapshot(try server("node serverA.js --token abc"))))
    }

    /// Ältere Snapshots ohne Fingerabdruck sind Baseline: kein Ereignis, aber neu gespeichert.
    @Test func olderSnapshotWithoutFingerprintProducesNoEvent() throws {
        let current = try server("node serverB.js --token abc")
        var legacy = try server("node serverA.js --token abc")
        legacy.transportFingerprint = nil
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object["transportFingerprint"] = nil
        let decoded = try JSONDecoder().decode(MCPServerEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.transportFingerprint == nil)

        #expect(events(from: decoded, to: current).isEmpty)
        #expect(!snapshot(decoded).isEquivalent(to: snapshot(current)))
    }

    /// Codex Runde 9 (Upgrade): `origin/main` (vor #137) speicherte das Skript teilmaskiert – Wert aus dessen
    /// `ArgumentRedactorTests.masksSecretsInsideShellStrings`. Der erste Scan nach dem Update verbirgt es ganz; das ist
    /// kein Ereignis, wird aber gespeichert.
    private static let mainScript = "export GITHUB_TOKEN=abc && npx server"
    private static let mainStoredScript = "export GITHUB_TOKEN=••• && npx server"

    /// Ein Eintrag, wie `origin/main` ihn gespeichert hat: alter Transport, kein `transportFingerprint`-Schlüssel.
    private func mainEntry(isEnabled: Bool? = nil, script: String = mainStoredScript) throws -> MCPServerEntry {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(try server(Self.mainScript))) as? [String: Any])
        object["transport"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MCPTransport.local(command: "sh", arguments: ["-c", script]))
        )
        object.removeValue(forKey: "transportFingerprint")
        if let isEnabled { object["isEnabled"] = isEnabled }
        return try JSONDecoder().decode(MCPServerEntry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func upgradeFromPartiallyMaskedScriptIsQuietButStored() throws {
        let legacy = try mainEntry()
        #expect(legacy.transportFingerprint == nil)
        let current = try server(Self.mainScript)
        #expect(current.transport == .local(command: "sh", arguments: ["-c", "•••"]))

        #expect(events(from: legacy, to: current).isEmpty)
        #expect(!snapshot(legacy).isEquivalent(to: snapshot(current)))
    }

    @Test func upgradeStillReportsSwitchAndVisibleTransportChanges() throws {
        var disabled = try server(Self.mainScript)
        disabled.isEnabled = false
        let switched = try #require(events(from: try mainEntry(isEnabled: true), to: disabled).first)
        #expect(ChangeDescription(switched).body.hasSuffix("deaktiviert"))

        let legacyVisible = try mainEntry(script: "node a.js")
        let changed = try #require(events(from: legacyVisible, to: try server("node b.js")).first)
        #expect(changed.kind == .modified)
    }

    /// Codex Runde 10: `origin/main` zerlegte `&&` ohne Leerraum nicht – `hunter2` stand im gespeicherten Alt-Skript im
    /// Klartext. Nach dem Update darf es über kein Ereignis (Vorher/Nachher, Text, JSON) wieder sichtbar werden.
    @Test func upgradeWithSwitchChangeNeverShowsTheLegacyScript() throws {
        let leakyMainScript = "export GITHUB_TOKEN=••• && true&&API_TOKEN=hunter2 run"
        let legacy = try mainEntry(isEnabled: true, script: leakyMainScript)
        #expect(legacy.transport == .local(command: "sh", arguments: ["-c", "•••"]))
        var current = try server(Self.mainScript)
        current.isEnabled = false

        let event = try #require(events(from: legacy, to: current).first)
        #expect(event.commandChange == nil)
        #expect(ChangeDescription(event).body.hasSuffix("deaktiviert"))
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("hunter2") && !encoded.contains("GITHUB_TOKEN"))
    }

    /// Auch ein Alteintrag, der nicht aus dem Speicher kommt, erscheint im Vorher/Nachher nur normalisiert.
    @Test func commandChangeNormalizesEntriesWithoutFingerprint() throws {
        var legacy = try server(Self.mainScript)
        legacy.transportFingerprint = nil
        legacy.transport = .local(command: "sh", arguments: ["-c", "export GITHUB_TOKEN=••• && true&&API_TOKEN=hunter2 run"])
        legacy.isEnabled = true
        var current = try server(Self.mainScript)
        current.isEnabled = false
        let event = ChangeEvent(kind: .modified, before: .mcpServer(legacy), after: .mcpServer(current), detectedAt: later)
        #expect(event.commandChange == nil)
        let changed = ChangeEvent(kind: .modified, before: .mcpServer(legacy), after: .mcpServer(try server("node b.js")),
                                  detectedAt: later)
        #expect(changed.commandChange == CommandChange(before: "sh -c •••", after: "sh -c 'node b.js'"))
    }

    /// Ein anderer Schlüssel macht Fingerabdrücke unvergleichbar: kein Ereignis.
    @Test func differentKeysProduceNoEvent() throws {
        let old = try server("node serverA.js --token abc", fingerprinter: .ephemeral())
        let new = try server("node serverB.js --token abc", fingerprinter: .ephemeral())
        #expect(events(from: old, to: new).isEmpty)
    }

    @Test func unmaskedTransportCarriesNoFingerprint() throws {
        #expect(try server("node serverA.js").transportFingerprint == nil)
    }

    @Test func maskedURLCarriesAFingerprint() throws {
        let tool = try #require(AgentToolCatalog.standard.tool(id: "claudeDesktop"))
        let file = tool.files[0]
        let text = #"{"mcpServers": {"r": {"url": "https://h.example/mcp?token=abc"}}}"#
        let document = try ConfigParsing.parse(Data(text.utf8), syntax: .json, redaction: file.redaction)
        let entry = try #require(AgentConfigExtractor.extract(document, file: file, tool: tool, configPath: "/h/c.json").servers.first)
        #expect(entry.transportFingerprint != nil)
    }

    /// Der Inhalts-Stempel der Dateiüberwachung ändert sich mit dem verborgenen Skript.
    @Test func contentStampFollowsTheHiddenScript() throws {
        try ScratchDirectory.with { home in
            let file = home.appending(path: ".cursor/mcp.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Self.config("node serverA.js --token abc").utf8).write(to: file)
            let stamp = try #require(AgentConfigSource.contentStamps(catalog: TestData.userCatalog, home: home.path)[file.path])
            let first = stamp()
            try Data(Self.config("node serverB.js --token abc").utf8).write(to: file)
            #expect(stamp() != first)
        }
    }
}
