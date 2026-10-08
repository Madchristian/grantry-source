import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AgentConfigActionsTests {
    private struct Fixture {
        let home: String
        let actions: AgentConfigActions
        let backups: AgentConfigBackupStore

        func path(_ relative: String) -> String { home + "/" + relative }

        func write(_ text: String, to relative: String) throws {
            let path = path(relative)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(filePath: path))
        }

        func read(_ relative: String) throws -> String {
            try String(contentsOfFile: path(relative), encoding: .utf8)
        }

        /// Aktionen, deren Uhr `interference` ausführt – sie läuft zwischen Lesen und Ersetzen der Datei.
        func actions(interference: @escaping @Sendable () -> Void) -> AgentConfigActions {
            AgentConfigActions(catalog: TestData.userCatalog, home: home, backups: backups) {
                interference()
                return Date()
            }
        }

        /// Legt einen Beleg samt Sicherung an, wie Grantry ihn nach einer Änderung hinterlässt – `seconds` vor einer
        /// Stunde, damit er weder verfallen noch neuer als eine echte Änderung ist.
        @discardableResult
        func receipt(
            for server: AgentServerReference, at seconds: TimeInterval = 0, original: Data = Data("{}".utf8), resultDigest: String = "egal"
        ) throws -> AgentConfigChange {
            let change = AgentConfigChange(
                id: UUID(), kind: .removedServer, server: server, changedAt: Date(timeIntervalSinceNow: seconds - 3600),
                originalDigest: AgentConfigFileAccess.digest(of: original), resultDigest: resultDigest
            )
            try backups.save(change, original: original)
            backups.commit(change)
            return change
        }

        /// Der Eintrag, wie der Scan ihn liefert.
        func entry(_ name: String, in relative: String) async throws -> MCPServerEntry {
            let contribution = try await AgentConfigSource(catalog: TestData.userCatalog, home: home,
                                                           inspector: RecordingSigningInspector(result: .unknown)).collect()
            return try #require(contribution.agents.mcpServers.first { $0.name == name && $0.configPath == path(relative) })
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        try await ScratchDirectory.with(prefix: "agent-actions") { directory in
            let home = try #require(AgentConfigReader.canonicalPath(directory.path))
            let backups = AgentConfigBackupStore(root: URL(filePath: home + "/Grantry/AgentBackups"))
            let actions = AgentConfigActions(catalog: TestData.userCatalog, home: home, backups: backups)
            try await body(Fixture(home: home, actions: actions, backups: backups))
        }
    }

    private static let desktop = "Library/Application Support/Claude/claude_desktop_config.json"
    private static let desktopText = """
    {
      "mcpServers": {
        "files": { "command": "npx", "args": ["-y", "files"], "env": { "TOKEN": "GEHEIM" } },
        "git": { "command": "git-mcp" }
      }
    }

    """

    @Test func removesAndRestoresTheUnchangedFileExactly() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let entry = try await fixture.entry("git", in: Self.desktop)
            let change = try await fixture.actions.removeServer(entry)
            #expect(try fixture.read(Self.desktop) == Self.desktopText.replacingOccurrences(
                of: " },\n    \"git\": { \"command\": \"git-mcp\" }\n", with: " }\n"))
            #expect(change.kind == .removedServer && change.server == entry.reference)
            #expect(fixture.backups.changes() == [change])

            #expect(try await fixture.actions.restore(changeID: change.id) == .restoredFile)
            #expect(try fixture.read(Self.desktop) == Self.desktopText)
            #expect(fixture.backups.changes().isEmpty)
        }
    }

    @Test func restoreReinsertsWhenTheFileChangedMeanwhile() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let change = try await fixture.actions.removeServer(try await fixture.entry("files", in: Self.desktop))
            let removed = try fixture.read(Self.desktop)
            try fixture.write(removed.replacingOccurrences(of: "git-mcp", with: "git-mcp2"), to: Self.desktop)
            #expect(try await fixture.actions.restore(changeID: change.id) == .revertedEntry)
            let restored = try fixture.read(Self.desktop)
            #expect(restored.contains("git-mcp2") && restored.contains(#""TOKEN": "GEHEIM""#))
            await #expect(throws: AgentConfigEditError.changeNotFound) {
                _ = try await fixture.actions.restore(changeID: change.id)
            }
        }
    }

    @Test func restoreOfAnAlreadyRestoredServerChangesNothing() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let change = try await fixture.actions.removeServer(try await fixture.entry("git", in: Self.desktop))
            try fixture.write(Self.desktopText + " ", to: Self.desktop)
            #expect(try await fixture.actions.restore(changeID: change.id) == .alreadyRestored)
            #expect(try fixture.read(Self.desktop) == Self.desktopText + " ")
            #expect(fixture.backups.changes().isEmpty)
        }
    }

    @Test func restoreRefusesWhenAnotherServerTookTheName() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let change = try await fixture.actions.removeServer(try await fixture.entry("git", in: Self.desktop))
            let taken = Self.desktopText.replacingOccurrences(of: "git-mcp", with: "fremd")
            try fixture.write(taken, to: Self.desktop)
            await #expect(throws: AgentConfigEditError.nameTaken) { _ = try await fixture.actions.restore(changeID: change.id) }
            #expect(try fixture.read(Self.desktop) == taken)
            #expect(fixture.backups.changes() == [change])
            #expect(try fixture.backups.original(of: change) == Data(Self.desktopText.utf8))
        }
    }

    /// Gleicher Befehl, anderer Geheimwert: kein „schon da“ – sonst ginge mit der Sicherung der alte Wert verloren.
    @Test func restoreRefusesAServerWithChangedSecrets() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let change = try await fixture.actions.removeServer(try await fixture.entry("files", in: Self.desktop))
            let changed = Self.desktopText.replacingOccurrences(of: "GEHEIM", with: "ANDERS")
            try fixture.write(changed, to: Self.desktop)
            await #expect(throws: AgentConfigEditError.nameTaken) { _ = try await fixture.actions.restore(changeID: change.id) }
            #expect(try fixture.read(Self.desktop) == changed)
            #expect(fixture.backups.changes() == [change])
            #expect(try fixture.backups.original(of: change) == Data(Self.desktopText.utf8))
        }
    }

    @Test func restoreOfAByteIdenticalServerChangesNothing() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let change = try await fixture.actions.removeServer(try await fixture.entry("files", in: Self.desktop))
            let recreated = Self.desktopText.replacingOccurrences(of: "git-mcp", with: "git-mcp2")
            try fixture.write(recreated, to: Self.desktop)
            #expect(try await fixture.actions.restore(changeID: change.id) == .alreadyRestored)
            #expect(try fixture.read(Self.desktop) == recreated)
            #expect(fixture.backups.changes().isEmpty)
        }
    }

    @Test func restoreOfADeletedFileFailsAndKeepsTheReceipt() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let change = try await fixture.actions.removeServer(try await fixture.entry("git", in: Self.desktop))
            try FileManager.default.removeItem(atPath: fixture.path(Self.desktop))
            await #expect(throws: AgentConfigEditError.missing) { _ = try await fixture.actions.restore(changeID: change.id) }
            #expect(fixture.backups.changes() == [change])
        }
    }

    /// Ein Beleg ist nur so vertrauenswürdig wie seine Ablage: Wiederherstellen prüft den Bereich wie jede Änderung.
    @Test func restoreRefusesManagedReceipts() async throws {
        try await withFixture { fixture in
            let managed = AgentServerReference(
                toolID: "claudeCode", toolName: "Claude Code", configPath: "/Library/Application Support/ClaudeCode/managed-mcp.json",
                registryPath: nil, scope: .system, name: "m"
            )
            let change = try fixture.receipt(for: managed)
            await #expect(throws: ActionError.notAllowed(.managedConfiguration)) { _ = try await fixture.actions.restore(changeID: change.id) }
            #expect(fixture.backups.changes() == [change])
        }
    }

    /// Ein Beleg mit einem Projekt, das die Registerdatei nicht (mehr) kennt, legt nichts zurück – auch wenn die
    /// Prüfsumme der Datei passt.
    @Test func restoreRefusesProjectsMissingFromTheRegistry() async throws {
        try await withFixture { fixture in
            let registry = "{\n  \"projects\": {\n    \"\(fixture.path("web"))\": { \"mcpServers\": { \"db\": { \"command\": \"db\" } } }\n  }\n}\n"
            try fixture.write(registry, to: ".claude.json")
            let projectFile = #"{"mcpServers": {"x": {"command": "x"}}}"#
            try fixture.write(projectFile, to: "fremd/.mcp.json")
            let inRegistry = AgentServerReference(
                toolID: "claudeCode", toolName: "Claude Code", configPath: fixture.path(".claude.json"), registryPath: nil,
                scope: .project(path: fixture.path("fremd")), name: "db"
            )
            let inProjectFile = AgentServerReference(
                toolID: "claudeCode", toolName: "Claude Code", configPath: fixture.path("fremd/.mcp.json"),
                registryPath: fixture.path(".claude.json"), scope: .project(path: fixture.path("fremd")), name: "x"
            )
            for (server, contents) in [(inRegistry, registry), (inProjectFile, projectFile)] {
                let change = try fixture.receipt(for: server, original: Data("{}".utf8),
                                                 resultDigest: AgentConfigFileAccess.digest(of: Data(contents.utf8)))
                await #expect(throws: AgentConfigEditError.notEditable("Das Projekt ist Grantry nicht bekannt")) {
                    _ = try await fixture.actions.restore(changeID: change.id)
                }
                #expect(fixture.backups.change(id: change.id) == change)
            }
            #expect(try fixture.read(".claude.json") == registry)
            #expect(try fixture.read("fremd/.mcp.json") == projectFile)
        }
    }

    /// Gegenprobe: Ein Beleg, dessen Projektpfad nur ähnlich geschrieben ist (abschließender Slash, andere
    /// Groß-/Kleinschreibung), trifft kein Projekt der Registerdatei – nichts wird zurückgelegt.
    @Test func restoreRefusesProjectPathsSpelledDifferently() async throws {
        try await withFixture { fixture in
            let registry = "{\n  \"projects\": {\n    \"\(fixture.path("web"))\": { \"mcpServers\": {} }\n  }\n}\n"
            try fixture.write(registry, to: ".claude.json")
            let projectFile = #"{"mcpServers": {}}"#
            try fixture.write(projectFile, to: "web/.mcp.json")
            for projectPath in [fixture.path("web") + "/", fixture.path("WEB")] {
                let inRegistry = AgentServerReference(
                    toolID: "claudeCode", toolName: "Claude Code", configPath: fixture.path(".claude.json"), registryPath: nil,
                    scope: .project(path: projectPath), name: "db"
                )
                let inProjectFile = AgentServerReference(
                    toolID: "claudeCode", toolName: "Claude Code", configPath: (projectPath as NSString).appendingPathComponent(".mcp.json"),
                    registryPath: fixture.path(".claude.json"), scope: .project(path: projectPath), name: "x"
                )
                for server in [inRegistry, inProjectFile] {
                    let change = try fixture.receipt(for: server)
                    await #expect(throws: AgentConfigEditError.notEditable("Das Projekt ist Grantry nicht bekannt")) {
                        _ = try await fixture.actions.restore(changeID: change.id)
                    }
                    #expect(fixture.backups.change(id: change.id) == change)
                }
            }
            #expect(try fixture.read(".claude.json") == registry)
            #expect(try fixture.read("web/.mcp.json") == projectFile)
        }
    }

    /// Gegenprobe: Ein Beleg mit einer fremden Registerdatei ist nicht Grantrys Ziel – gleicher Grund wie beim Schloss.
    @Test func restoreRefusesAForeignRegistryPath() async throws {
        try await withFixture { fixture in
            try fixture.write("{\"projects\": {\"\(fixture.path("web"))\": {}}}", to: "fremd.json")
            try fixture.write(#"{"mcpServers": {}}"#, to: "web/.mcp.json")
            let server = AgentServerReference(
                toolID: "claudeCode", toolName: "Claude Code", configPath: fixture.path("web/.mcp.json"),
                registryPath: fixture.path("fremd.json"), scope: .project(path: fixture.path("web")), name: "x"
            )
            let change = try fixture.receipt(for: server)
            await #expect(throws: ActionError.notAllowed(.unknownConfiguration)) {
                _ = try await fixture.actions.restore(changeID: change.id)
            }
            #expect(fixture.backups.change(id: change.id) == change)
        }
    }

    /// Gegenprobe TOML: Steht der Server mit verstreuten Untertabellen wieder byte-gleich in der (sonst geänderten)
    /// Datei, ist das „schon wiederhergestellt“.
    @Test func restoreRecognizesAScatteredTOMLEntryAsAlreadyRestored() async throws {
        try await withFixture { fixture in
            let config = "model = \"o3\"\n\n[mcp_servers.x]\ncommand = \"x\"\n\n[other]\na = 1\n\n[mcp_servers.x.env]\nK = \"GEHEIM\"\n"
            try fixture.write(config, to: ".codex/config.toml")
            let change = try await fixture.actions.removeServer(try await fixture.entry("x", in: ".codex/config.toml"))
            #expect(try fixture.read(".codex/config.toml") == "model = \"o3\"\n\n[other]\na = 1\n")
            let changed = config.replacingOccurrences(of: "o3", with: "o4")
            try fixture.write(changed, to: ".codex/config.toml")
            #expect(try await fixture.actions.restore(changeID: change.id) == .alreadyRestored)
            #expect(try fixture.read(".codex/config.toml") == changed)
        }
    }

    /// BOM und CRLF bleiben beim Entfernen und beim Wiedereinfügen in eine inzwischen geänderte Datei erhalten.
    @Test func keepsByteOrderMarkAndCRLFAcrossRemoveAndRestore() async throws {
        try await withFixture { fixture in
            // `String(contentsOfFile:)` verschluckte die BOM – byte-genau vergleichen.
            func bytes(_ relative: String) throws -> Data { try Data(contentsOf: URL(filePath: fixture.path(relative))) }
            let text = "\u{FEFF}{\r\n  \"mcpServers\": {\r\n    \"a\": { \"command\": \"a\" },\r\n    \"b\": { \"command\": \"b\" }\r\n  }\r\n}\r\n"
            try fixture.write(text, to: Self.desktop)
            let change = try await fixture.actions.removeServer(try await fixture.entry("b", in: Self.desktop))
            let removed = "\u{FEFF}{\r\n  \"mcpServers\": {\r\n    \"a\": { \"command\": \"a\" }\r\n  }\r\n}\r\n"
            #expect(try bytes(Self.desktop) == Data(removed.utf8))
            let changed = removed.replacingOccurrences(of: "\"command\": \"a\"", with: "\"command\": \"a2\"")
            try fixture.write(changed, to: Self.desktop)
            #expect(try await fixture.actions.restore(changeID: change.id) == .revertedEntry)
            #expect(try bytes(Self.desktop) == Data(text.replacingOccurrences(of: "\"command\": \"a\"", with: "\"command\": \"a2\"").utf8))
        }
    }

    /// Die Registerdatei wird beim Wiederherstellen nur gelesen – wie im Scan, ein Symlink innerhalb des Benutzerordners
    /// ist dort erlaubt. Die Projektdatei selbst bleibt streng.
    @Test func restoreOfAProjectFileServerReadsTheRegistryLikeTheScan() async throws {
        try await withFixture { fixture in
            let registry = "{\n  \"projects\": {\n    \"\(fixture.path("web"))\": {}\n  }\n}\n"
            try fixture.write(registry, to: "real/claude.json")
            try FileManager.default.createSymbolicLink(atPath: fixture.path(".claude.json"), withDestinationPath: fixture.path("real/claude.json"))
            let original = "{\"mcpServers\": {\"x\": {\"command\": \"x\", \"env\": {\"TOKEN\": \"GEHEIM\"}}}}\n"
            let removed = "{\"mcpServers\": {}}\n"
            try fixture.write(removed, to: "web/.mcp.json")
            let server = AgentServerReference(
                toolID: "claudeCode", toolName: "Claude Code", configPath: fixture.path("web/.mcp.json"),
                registryPath: fixture.path(".claude.json"), scope: .project(path: fixture.path("web")), name: "x"
            )
            let change = try fixture.receipt(for: server, original: Data(original.utf8),
                                             resultDigest: AgentConfigFileAccess.digest(of: Data(removed.utf8)))
            #expect(try await fixture.actions.restore(changeID: change.id) == .restoredFile)
            #expect(try fixture.read("web/.mcp.json") == original)
            #expect(fixture.backups.changes().isEmpty)
        }
    }

    /// Ein Symlink aus dem Benutzerordner heraus wird auch nur zum Lesen nicht verfolgt; die Meldung nennt die
    /// Registerdatei, die Projektdatei wird gar nicht erst geöffnet (sie fehlt hier – ohne `missing`-Fehler).
    @Test func restoreRefusesARegistryLinkedOutsideHomeBeforeOpeningTheProjectFile() async throws {
        let outside = FileManager.default.temporaryDirectory.appending(path: "outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try await withFixture { fixture in
            let target = outside.appending(path: "claude.json")
            try Data("{\"projects\": {\"\(fixture.path("web"))\": {}}}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(atPath: fixture.path(".claude.json"), withDestinationPath: target.path)
            let server = AgentServerReference(
                toolID: "claudeCode", toolName: "Claude Code", configPath: fixture.path("web/.mcp.json"),
                registryPath: fixture.path(".claude.json"), scope: .project(path: fixture.path("web")), name: "x"
            )
            let change = try fixture.receipt(for: server)
            let expected = AgentConfigEditError.unreadable("Registerdatei \(fixture.path(".claude.json")): verweist aus dem Benutzerordner heraus")
            await #expect(throws: expected) { _ = try await fixture.actions.restore(changeID: change.id) }
            try FileManager.default.removeItem(atPath: fixture.path(".claude.json"))
            await #expect(throws: AgentConfigEditError.notEditable("Die Registerdatei \(fixture.path(".claude.json")) fehlt")) {
                _ = try await fixture.actions.restore(changeID: change.id)
            }
            try fixture.write("{\"projects\": {}}", to: ".claude.json")
            await #expect(throws: AgentConfigEditError.notEditable("Das Projekt ist Grantry nicht bekannt")) {
                _ = try await fixture.actions.restore(changeID: change.id)
            }
            try fixture.write("{", to: ".claude.json")
            var failure: AgentConfigEditError?
            do { _ = try await fixture.actions.restore(changeID: change.id) } catch let error as AgentConfigEditError { failure = error }
            guard case .unreadable(let reason)? = failure else { Issue.record("Erwartet unreadable, erhalten \(String(describing: failure))"); return }
            #expect(reason.hasPrefix("Registerdatei \(fixture.path(".claude.json")): "))
            #expect(fixture.backups.changes() == [change])
        }
    }

    /// Kennt der Katalog Tool oder Datei nicht, meldet das Wiederherstellen denselben Grund wie das Schloss bei
    /// „Aktionen“ (`unknownConfiguration`) – ein Text aus einer Quelle.
    @Test func restoreReportsUnknownTargetsLikeTheLock() async throws {
        try await withFixture { fixture in
            let unknownTool = AgentServerReference(toolID: "fremd", toolName: "Fremd", configPath: fixture.path(".fremd/mcp.json"),
                                                   registryPath: nil, scope: .user, name: "x")
            let unknownFile = AgentServerReference(toolID: "cursor", toolName: "Cursor", configPath: fixture.path(".cursor/andere.json"),
                                                   registryPath: nil, scope: .user, name: "x")
            let toolChange = try fixture.receipt(for: unknownTool)
            let fileChange = try fixture.receipt(for: unknownFile)
            #expect(AgentEditCapabilities(reference: unknownTool, isEnabled: nil, home: fixture.home).availability
                == .readOnly(.unknownConfiguration))
            await #expect(throws: ActionError.notAllowed(.unknownConfiguration)) {
                _ = try await fixture.actions.restore(changeID: toolChange.id)
            }
            await #expect(throws: ActionError.notAllowed(.unknownConfiguration)) {
                _ = try await fixture.actions.restore(changeID: fileChange.id)
            }
            #expect(fixture.backups.changes().count == 2)
        }
    }

    @Test func switchesAProjectServerByNameListAndRevertsAfterOtherChanges() async throws {
        try await withFixture { fixture in
            let registry = """
            {
              "numStartups": 1,
              "projects": {
                "\(fixture.path("web"))": {
                  "mcpServers": { "db": { "command": "db" } },
                  "disabledMcpServers": []
                }
              }
            }

            """
            try fixture.write(registry, to: ".claude.json")
            let entry = try await fixture.entry("db", in: ".claude.json")
            let change = try await fixture.actions.setEnabled(entry, false)
            #expect(try fixture.read(".claude.json").contains(#""disabledMcpServers": ["db"]"#))
            try fixture.write(try fixture.read(".claude.json").replacingOccurrences(of: "\"numStartups\": 1", with: "\"numStartups\": 2"),
                              to: ".claude.json")
            #expect(try await fixture.actions.restore(changeID: change.id) == .revertedEntry)
            #expect(try fixture.read(".claude.json") == registry.replacingOccurrences(of: "\"numStartups\": 1", with: "\"numStartups\": 2"))
            #expect(fixture.backups.changes().isEmpty)
        }
    }

    /// Steht die neue Fassung trotz gescheiterter Nachprüfung in der Datei, bleiben Sicherung und Beleg – committet,
    /// damit sie im Verlauf erscheinen (ältere über die Grenze hinaus werden aufgeräumt) –, und der Fehler wird gemeldet.
    @Test func failedSwapBackKeepsTheBackupAndReceipt() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let entry = try await fixture.entry("git", in: Self.desktop)
            let older = try (0..<AgentConfigBackupStore.retainedChangesPerFile).map { seconds in
                try fixture.receipt(for: entry.reference, at: TimeInterval(seconds))
            }
            let directory = (fixture.path(Self.desktop) as NSString).deletingLastPathComponent
            let actions = AgentConfigActions(catalog: TestData.userCatalog, home: fixture.home, backups: fixture.backups, now: Date.init) {
                snapshot, contents throws(AgentConfigEditError) in
                try AgentConfigFileAccess.replace(snapshot, with: contents) {
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasSuffix(".tmp") {
                        unlink(directory + "/" + name)
                    }
                }
            }
            var failure: AgentConfigEditError?
            do {
                _ = try await actions.removeServer(entry)
            } catch let error as AgentConfigEditError {
                failure = error
            }
            guard case .replacedUnverified? = failure else {
                Issue.record("Erwartet replacedUnverified, erhalten \(String(describing: failure))")
                return
            }
            #expect(!(try fixture.read(Self.desktop)).contains("git-mcp"))
            let changes = fixture.backups.changes()
            let kept = try #require(changes.first)
            #expect(kept.server == entry.reference && kept.originalDigest == AgentConfigFileAccess.digest(of: Data(Self.desktopText.utf8)))
            #expect(try fixture.backups.original(of: kept) == Data(Self.desktopText.utf8))
            #expect(Array(changes.dropFirst()) == Array(older.reversed().prefix(AgentConfigBackupStore.retainedChangesPerFile - 1)))
        }
    }

    /// Ältere Sicherungen werden erst nach erfolgreichem Ersetzen aufgeräumt.
    @Test func failedChangeKeepsAllOlderBackups() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let entry = try await fixture.entry("git", in: Self.desktop)
            let older = try (0..<AgentConfigBackupStore.retainedChangesPerFile).map { seconds in
                try fixture.receipt(for: entry.reference, at: TimeInterval(seconds))
            }
            let path = fixture.path(Self.desktop)
            let interfering = fixture.actions {
                try? Data((Self.desktopText + " ").utf8).write(to: URL(filePath: path))
            }
            await #expect(throws: AgentConfigEditError.fileChanged) { _ = try await interfering.removeServer(entry) }
            #expect(fixture.backups.changes() == older.reversed())
            #expect(try fixture.read(Self.desktop) == Self.desktopText + " ")
        }
    }

    @Test func switchesCodexAndRevertsAfterOtherChanges() async throws {
        try await withFixture { fixture in
            let codex = ".codex/config.toml"
            try fixture.write("model = \"o3\"\n\n[mcp_servers.alpha]\ncommand = \"alpha\"\n", to: codex)
            let entry = try await fixture.entry("alpha", in: codex)
            #expect(entry.editCapabilities(catalog: TestData.userCatalog, home: fixture.home).canSwitch)
            let change = try await fixture.actions.setEnabled(entry, false)
            #expect(try fixture.read(codex) == "model = \"o3\"\n\n[mcp_servers.alpha]\nenabled = false\ncommand = \"alpha\"\n")
            try fixture.write(try fixture.read(codex).replacingOccurrences(of: "o3", with: "o4"), to: codex)
            #expect(try await fixture.actions.restore(changeID: change.id) == .revertedEntry)
            #expect(try fixture.read(codex) == "model = \"o4\"\n\n[mcp_servers.alpha]\nenabled = true\ncommand = \"alpha\"\n")
        }
    }

    /// Regression (Codex-Review 2026.10.6, #155): Ein alter Beleg stellt keinen Server an, der inzwischen ein anderer
    /// ist (anderer Befehl unter demselben Namen): `nameTaken`, Datei und Sicherung bleiben – auch wenn der Schalter
    /// schon wieder den früheren Stand hätte.
    @Test func restoreOfAToggleRefusesAReplacedServer() async throws {
        try await withFixture { fixture in
            let codex = ".codex/config.toml"
            try fixture.write("[mcp_servers.alpha]\ncommand = \"alpha\"\n", to: codex)
            let entry = try await fixture.entry("alpha", in: codex)
            let change = try await fixture.actions.setEnabled(entry, false)
            for replaced in ["[mcp_servers.alpha]\nenabled = false\ncommand = \"beta\"\n", "[mcp_servers.alpha]\ncommand = \"beta\"\n"] {
                try fixture.write(replaced, to: codex)
                await #expect(throws: AgentConfigEditError.nameTaken) { _ = try await fixture.actions.restore(changeID: change.id) }
                #expect(try fixture.read(codex) == replaced)
                #expect(fixture.backups.changes() == [change])
            }
        }
    }

    /// Dasselbe für die Namensliste eines Projekts: Der Server in der Registerdatei muss noch der gesicherte sein.
    @Test func restoreOfANameListToggleRefusesAReplacedServer() async throws {
        try await withFixture { fixture in
            let registry = """
            {
              "projects": {
                "\(fixture.path("web"))": {
                  "mcpServers": { "db": { "command": "db" } },
                  "disabledMcpServers": []
                }
              }
            }

            """
            try fixture.write(registry, to: ".claude.json")
            let entry = try await fixture.entry("db", in: ".claude.json")
            let change = try await fixture.actions.setEnabled(entry, false)
            let replaced = try fixture.read(".claude.json").replacingOccurrences(of: "\"command\": \"db\"", with: "\"command\": \"other\"")
            try fixture.write(replaced, to: ".claude.json")
            await #expect(throws: AgentConfigEditError.nameTaken) { _ = try await fixture.actions.restore(changeID: change.id) }
            #expect(try fixture.read(".claude.json") == replaced)
            #expect(fixture.backups.changes() == [change])
        }
    }

    @Test func refusesChangedEntriesWithoutLeavingABackup() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.desktopText, to: Self.desktop)
            let entry = try await fixture.entry("git", in: Self.desktop)
            try fixture.write(Self.desktopText.replacingOccurrences(of: "git-mcp", with: "anders"), to: Self.desktop)
            await #expect(throws: AgentConfigEditError.entryChanged) { _ = try await fixture.actions.removeServer(entry) }
            #expect(fixture.backups.changes().isEmpty)
        }
    }

    @Test func refusesManagedAndForeignFiles() async throws {
        try await withFixture { fixture in
            let managed = TestData.mcpServer("m", toolID: "claudeCode", toolName: "Claude Code",
                                             configPath: "/Library/Application Support/ClaudeCode/managed-mcp.json", scope: .system)
            await #expect(throws: ActionError.notAllowed(.managedConfiguration)) { _ = try await fixture.actions.removeServer(managed) }
            let outside = TestData.mcpServer("o", configPath: "/etc/claude_desktop_config.json")
            await #expect(throws: ActionError.notAllowed(.configurationOutsideHome)) { _ = try await fixture.actions.removeServer(outside) }
            let symlinked = TestData.mcpServer("files", configPath: fixture.path(Self.desktop))
            try fixture.write(Self.desktopText, to: "real.json")
            try FileManager.default.createDirectory(atPath: fixture.path("Library/Application Support/Claude"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: fixture.path(Self.desktop), withDestinationPath: fixture.path("real.json"))
            await #expect(throws: AgentConfigEditError.notEditable("Der Pfad enthält einen symbolischen Link")) {
                _ = try await fixture.actions.removeServer(symlinked)
            }
        }
    }

    // MARK: Verborgene Befehle (#137)

    private static func scriptConfig(_ script: String) -> String {
        #"{"mcpServers": {"s": {"command": "sh", "args": ["-c", "\#(script)"]}, "git": {"command": "git-mcp"}}}"#
    }

    /// Scan und Bearbeiten mit dem dauerhaften Schlüssel des Ablageorts – je eigene Instanz wie nach einem Neustart.
    private func hiddenScriptFixture(
        _ body: (Fixture, _ scan: () async throws -> MCPServerEntry, _ actions: AgentConfigActions) async throws -> Void
    ) async throws {
        try await withFixture { fixture in
            let keyURL = URL(filePath: fixture.home + "/Grantry/SecretFingerprint.key")
            let scan = {
                let contribution = try await AgentConfigSource(
                    catalog: TestData.userCatalog, home: fixture.home, inspector: RecordingSigningInspector(result: .unknown),
                    fingerprinter: .persistent(at: keyURL)
                ).collect()
                return try #require(contribution.agents.mcpServers.first { $0.name == "s" })
            }
            let actions = AgentConfigActions(
                catalog: TestData.userCatalog, home: fixture.home, backups: fixture.backups,
                fingerprinter: .persistent(at: keyURL)
            )
            try await body(fixture, scan, actions)
        }
    }

    @Test func hiddenScriptChangedSinceTheScanIsNotRemoved() async throws {
        try await hiddenScriptFixture { fixture, scan, actions in
            try fixture.write(Self.scriptConfig("node serverA.js --token abc"), to: Self.desktop)
            let entry = try await scan()
            #expect(entry.transport == .local(command: "sh", arguments: ["-c", "•••"]))
            try fixture.write(Self.scriptConfig("node serverB.js --token abc"), to: Self.desktop)
            await #expect(throws: AgentConfigEditError.entryChanged) { _ = try await actions.removeServer(entry) }
            await #expect(throws: AgentConfigEditError.entryChanged) { _ = try await actions.setEnabled(entry, false) }
            #expect(try fixture.read(Self.desktop).contains("serverB.js"))
            #expect(fixture.backups.changes().isEmpty)
        }
    }

    @Test func unchangedHiddenScriptIsRemovedWithTheSameKeyAcrossInstances() async throws {
        try await hiddenScriptFixture { fixture, scan, actions in
            try fixture.write(Self.scriptConfig("node serverA.js --token abc"), to: Self.desktop)
            let entry = try await scan()
            _ = try await actions.removeServer(entry)
            #expect(!(try fixture.read(Self.desktop)).contains("serverA.js"))
        }
    }

    /// Nicht vergleichbare Fingerabdrücke (anderer Schlüssel) bei verborgenem Befehl: lieber neu scannen.
    @Test func hiddenScriptWithIncomparableFingerprintIsNotRemoved() async throws {
        try await withFixture { fixture in
            try fixture.write(Self.scriptConfig("node serverA.js --token abc"), to: Self.desktop)
            let contribution = try await AgentConfigSource(
                catalog: TestData.userCatalog, home: fixture.home, inspector: RecordingSigningInspector(result: .unknown),
                fingerprinter: .ephemeral()
            ).collect()
            let entry = try #require(contribution.agents.mcpServers.first { $0.name == "s" })
            await #expect(throws: AgentConfigEditError.entryChanged) { _ = try await fixture.actions.removeServer(entry) }
            // Ohne Verborgenes stört der Schlüssel nicht.
            let git = try #require(contribution.agents.mcpServers.first { $0.name == "git" })
            _ = try await fixture.actions.removeServer(git)
        }
    }
}

@Suite struct AgentEditCapabilitiesTests {
    private let home = "/Users/test"

    @Test func capabilitiesFollowScopeCatalogAndSwitch() {
        let desktop = TestData.mcpServer("a", configPath: home + "/Library/Application Support/Claude/claude_desktop_config.json")
        let capabilities = desktop.editCapabilities(home: home)
        #expect(capabilities.availability == .available && !capabilities.canSwitch && !capabilities.toolRewritesFile)
        let codex = TestData.mcpServer("c", toolID: "codex", toolName: "Codex", configPath: home + "/.codex/config.toml", isEnabled: true)
        #expect(codex.editCapabilities(home: home).canSwitch)
        let managed = TestData.mcpServer("m", toolID: "claudeCode", configPath: "/Library/Application Support/ClaudeCode/managed-mcp.json",
                                         scope: .system)
        #expect(managed.editCapabilities(home: home).availability == .readOnly(.managedConfiguration))
        let unknown = TestData.mcpServer("u", toolID: "cursor", configPath: home + "/.cursor/andere.json")
        #expect(unknown.editCapabilities(home: home).availability == .readOnly(.unknownConfiguration))
        let project = TestData.mcpServer("p", toolID: "claudeCode", toolName: "Claude Code", configPath: home + "/.claude.json",
                                         scope: .project(path: home + "/web"), isEnabled: true)
        let projectCapabilities = project.editCapabilities(home: home)
        #expect(projectCapabilities.canSwitch && projectCapabilities.toolRewritesFile)
        #expect(projectCapabilities.restartNote.hasPrefix("Beende Claude Code vorher"))
        let projectFile = TestData.mcpServer("f", toolID: "claudeCode", toolName: "Claude Code", configPath: home + "/web/.mcp.json",
                                             scope: .project(path: home + "/web"), registryPath: home + "/.claude.json")
        let fileCapabilities = projectFile.editCapabilities(home: home)
        #expect(fileCapabilities.availability == .available && !fileCapabilities.canSwitch && !fileCapabilities.toolRewritesFile)
        #expect(fileCapabilities.restartNote.contains("oft versioniert"))
    }

    /// Defense in depth: Auch ohne vorgeschaltete Fähigkeitsprüfung gibt es kein Ziel in verwalteten Dateien.
    @Test func targetsRefuseManagedFiles() {
        let managed = AgentEditing.reference("m", tool: "claudeCode", path: "/Library/Application Support/ClaudeCode/managed-mcp.json",
                                             scope: .system)
        #expect(throws: AgentConfigEditError.notEditable("Verwaltete Konfigurationen ändert Grantry nicht")) {
            try AgentServerTarget(reference: managed, catalog: .standard, home: home)
        }
    }
}
