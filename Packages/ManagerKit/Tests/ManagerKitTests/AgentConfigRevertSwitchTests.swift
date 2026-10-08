import Foundation
import Testing
@testable import ManagerKit

/// Regression (Codex-Review zu #155, Runde 3): Die Schalter-Wiederherstellung (`revertSwitch`) erkennt einen Server
/// an allen Feldern seines Eintrags außer dem Schalter – nicht nur am Transport. Ändert sich nur `env`
/// (`DATABASE_URL` Test → Prod), ein Header, eine Zugangsangabe oder ein anderes Feld, ist es nicht mehr der Server
/// aus dem Beleg: `nameTaken`, die Sicherung bleibt. Unverändert wird der Schalter zurückgestellt – je Format mit
/// Schalter (Codex-TOML, Windsurf-JSON mit `disabled`, Claude-Code-Namensliste).
@Suite struct AgentConfigRevertSwitchTests {
    /// Felder des Servers `db`, die zum Server gehören, aber nicht zum Transport.
    struct Fields: Sendable {
        var environment = "postgres://test"
        var header = "tenant-a"
        var credential = "T1-geheim"
        var workingDirectory = "/srv/test"
    }

    enum Format: CaseIterable, Sendable {
        case codexTOML, windsurfJSON, claudeCodeNameList

        var reference: AgentServerReference {
            switch self {
            case .codexTOML:
                AgentEditing.reference("db", tool: AgentEditing.codex.tool, path: AgentEditing.codex.path)
            case .windsurfJSON:
                AgentEditing.reference("db", tool: AgentEditing.windsurf.tool, path: AgentEditing.windsurf.path)
            case .claudeCodeNameList:
                AgentEditing.reference("db", tool: AgentEditing.claudeCode.tool, path: AgentEditing.claudeCode.path,
                                       scope: .project(path: "/Users/test/web"))
            }
        }

        /// Die Datei mit dem Server `db`; `switchedOff`: der Schalter steht auf „aus“.
        func text(_ fields: Fields, switchedOff: Bool) -> String {
            switch self {
            case .codexTOML:
                """
                [mcp_servers.db]
                url = "https://db.example/mcp"
                cwd = "\(fields.workingDirectory)"
                bearer_token = "\(fields.credential)"
                enabled = \(!switchedOff)

                [mcp_servers.db.env]
                DATABASE_URL = "\(fields.environment)"

                [mcp_servers.db.http_headers]
                X-Tenant = "\(fields.header)"

                """
            case .windsurfJSON:
                """
                {
                  "mcpServers": {
                    "db": {
                      "command": "db",
                      "cwd": "\(fields.workingDirectory)",
                      "env": { "DATABASE_URL": "\(fields.environment)" },
                      "headers": { "X-Tenant": "\(fields.header)" },
                      "oauth": { "clientSecret": "\(fields.credential)" },
                      "disabled": \(switchedOff)
                    }
                  }
                }

                """
            case .claudeCodeNameList:
                """
                {
                  "projects": {
                    "/Users/test/web": {
                      "mcpServers": {
                        "db": {
                          "command": "db",
                          "cwd": "\(fields.workingDirectory)",
                          "env": { "DATABASE_URL": "\(fields.environment)" },
                          "headers": { "X-Tenant": "\(fields.header)" },
                          "oauth": { "clientSecret": "\(fields.credential)" }
                        }
                      },
                      "disabledMcpServers": [\(switchedOff ? "\"db\"" : "")]
                    }
                  }
                }

                """
            }
        }
    }

    enum Change: CaseIterable, Sendable {
        case environment, header, credential, workingDirectory

        func applied(to fields: Fields) -> Fields {
            var changed = fields
            switch self {
            case .environment: changed.environment = "postgres://prod"
            case .header: changed.header = "tenant-b"
            case .credential: changed.credential = "T2-geheim"
            case .workingDirectory: changed.workingDirectory = "/srv/prod"
            }
            return changed
        }
    }

    @Test(arguments: Format.allCases, Change.allCases)
    func changedServerIsNotSwitchedBack(format: Format, change: Change) throws {
        let editor = try AgentEditing.editor(format.reference)
        let backup = Data(format.text(Fields(), switchedOff: false).utf8)
        let replaced = Data(format.text(change.applied(to: Fields()), switchedOff: true).utf8)
        #expect(throws: AgentConfigEditError.nameTaken) {
            _ = try editor.revertSwitch(to: true, from: backup, into: replaced)
        }
    }

    @Test(arguments: Format.allCases)
    func unchangedServerIsSwitchedBack(format: Format) throws {
        let editor = try AgentEditing.editor(format.reference)
        let backup = Data(format.text(Fields(), switchedOff: false).utf8)
        let current = Data(format.text(Fields(), switchedOff: true).utf8)
        #expect(try editor.revertSwitch(to: true, from: backup, into: current) == backup)
    }
}
