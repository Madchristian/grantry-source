import Foundation
import GrantryShared

/// Testdaten für `SecurityHardening`: Ausgaben der Zustandsabfragen und ein Runner, der eine Operation vollständig
/// durchlaufen lässt.
public enum SecurityHardeningStubs {
    /// Ergebnis der Zustandsabfrage von `operation`, bei dem der Helper noch setzen muss (Schutz aus) – mit dem
    /// Exit-Code, den macOS dabei liefert; `nil` ohne Abfrage.
    public static func resultRequiringAction(for operation: SecurityHardening) -> CommandResult? {
        switch operation {
        case .enableFirewall: try? fixtureResult("socketfilterfw-off.txt")
        case .enableStealthMode: CommandResult(exitCode: 0, stdout: "Firewall stealth mode is off\n")
        case .enableGatekeeper: try? fixtureResult("spctl-disabled.txt")
        case .enableAutomaticUpdates, .updateXProtect: nil
        }
    }

    /// Befehlszeilen, die der Helper für `operation` bei ausgeschaltetem Schutz nacheinander ausführt.
    public static func commandLinesRequiringAction(for operation: SecurityHardening) -> [String] {
        (operation.stateQuery.map { [$0.invocation.commandLine] } ?? []) + operation.invocations.map(\.commandLine)
    }

    /// Runner, an dem `operation` bei ausgeschaltetem Schutz erfolgreich alle Befehle ausführt.
    public static func runnerRequiringAction(for operation: SecurityHardening) -> MockCommandRunner {
        let runner = MockCommandRunner()
        if let query = operation.stateQuery, let result = resultRequiringAction(for: operation) {
            runner.stub(query.invocation.commandLine, result)
        }
        for invocation in operation.invocations {
            runner.stub(invocation.commandLine, CommandResult(exitCode: 0, stdout: ""))
        }
        return runner
    }

    /// Inhalt der Fixture `Tests/ManagerKitTests/Fixtures/Security/<name>` (dieselben Ausgaben, die die App liest).
    public static func fixture(_ name: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ManagerKitTests/Fixtures/Security/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Exit-Codes, mit denen macOS die Ausgabe einer Fixture liefert, sofern ≠ 0. Die Fixtures selbst enthalten nur
    /// stdout; hier steht, was dazugehört.
    ///
    /// `spctl --status` endet bei „assessments disabled“ mit Exit 1 (spctl.cpp: `printf("assessments disabled\n");
    /// exit(1);`) – die Ausgabe ist trotzdem ein gültiger Zustand.
    public static let fixtureExitCodes: [String: Int32] = ["spctl-disabled.txt": 1]

    /// Fixture `name` als Befehlsergebnis mit dem Exit-Code, den macOS dazu liefert (`fixtureExitCodes`, sonst 0).
    public static func fixtureResult(_ name: String) throws -> CommandResult {
        CommandResult(exitCode: fixtureExitCodes[name] ?? 0, stdout: try fixture(name))
    }
}
