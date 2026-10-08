import Testing
import Foundation
@testable import ManagerKit
import TestSupport

@Suite struct ErrorDescriptionTests {
    @Test func tccReadErrors() {
        #expect(TCCReadError.cannotOpen("unable to open database file").errorDescription
            == "TCC-Datenbank konnte nicht geöffnet werden: unable to open database file")
        #expect(TCCReadError.missingColumns(["auth_value", "client"]).errorDescription
            == "TCC-Datenbank hat ein unbekanntes Schema, es fehlen Spalten: auth_value, client")
        #expect(TCCReadError.queryFailed("database is locked").errorDescription
            == "TCC-Datenbank konnte nicht gelesen werden: database is locked")
    }

    @Test func launchdSourceErrors() {
        #expect(LaunchdSourceError.launchctlFailed(domain: "gui/501", arguments: ["print", "gui/501"], exitCode: 1, message: "Bad request.")
            .errorDescription == "launchctl print gui/501 fehlgeschlagen (Exit 1): Bad request.")
        #expect(LaunchdSourceError.launchctlFailed(domain: "system", arguments: ["print", "system"], exitCode: 1, message: "")
            .errorDescription == "launchctl print system fehlgeschlagen (Exit 1)")
        #expect(LaunchdSourceError.launchctlFailed(domain: "system", arguments: ["print-disabled", "system"], exitCode: nil, message: "Zeitüberschreitung")
            .errorDescription == "launchctl print-disabled system fehlgeschlagen: Zeitüberschreitung")
    }

    @Test func btmSourceErrors() {
        #expect(BTMSourceError.helperUnavailable.errorDescription == "Hintergrund-Items nicht lesbar: Helper nicht erreichbar")
        #expect(BTMSourceError.unparseableDump.errorDescription
            == "Hintergrund-Items nicht lesbar: unerwartetes Ausgabeformat von sfltool dumpbtm")
        #expect(BTMSourceError.dumpFailed("sfltool dumpbtm fehlgeschlagen (Exit 1)").errorDescription
            == "Hintergrund-Items nicht lesbar: sfltool dumpbtm fehlgeschlagen (Exit 1)")
    }

    @Test func commandErrors() {
        #expect(CommandError.launchFailed(executable: "/bin/launchctl", reason: "not found").errorDescription
            == "/bin/launchctl konnte nicht gestartet werden: not found")
        #expect(CommandError.timedOut(executable: "/bin/launchctl", seconds: 30).errorDescription
            == "/bin/launchctl lieferte nach 30 s kein Ergebnis")
        #expect(CommandError.timedOut(executable: "/bin/launchctl", seconds: 0.5).errorDescription
            == "/bin/launchctl lieferte nach 0,5 s kein Ergebnis")
    }

    /// Ein Start-/Timeout-Fehler erscheint in der launchctl-Meldung mit seiner lesbaren Beschreibung.
    @Test func launchdSourceWrapsCommandErrorDescription() async throws {
        let runner = FailingRunner(error: CommandError.timedOut(executable: "/bin/launchctl", seconds: 30))
        let snapshot = try await ScratchDirectory.with(prefix: "launchd") { directory in
            let plist = try PropertyListSerialization.data(fromPropertyList: ["Label": "a", "Program": "/bin/ls"], format: .xml, options: 0)
            try plist.write(to: directory.appending(path: "a.plist"))
            let source = LaunchdSource(
                directories: [LaunchdDirectory(path: directory.path, kind: .launchAgent, domain: .user, launchctlDomain: "gui/501")],
                runner: runner, resolver: StubAppResolver()
            )
            return try await ScanCoordinator(sources: [source], now: { TestData.date }).scan()
        }
        #expect(snapshot.sourceErrors == [SourceError(
            source: .launchd, message: "launchctl print-disabled gui/501 fehlgeschlagen: /bin/launchctl lieferte nach 30 s kein Ergebnis"
        )])
    }

    @Test func scanCoordinatorUsesDescriptionsOfSourceErrors() async throws {
        let snapshot = try await ScanCoordinator(sources: [
            TCCSource(database: TCCDatabaseLocation(path: "/nonexistent/TCC.db", scope: .user), resolver: StubAppResolver()),
            BTMSource(provider: UnavailableProvider(), resolver: StubAppResolver()),
        ], now: { TestData.date }).scan()

        #expect(snapshot.sourceErrors == [
            SourceError(source: .tccUser, message: "TCC-Datenbank konnte nicht geöffnet werden: unable to open database file"),
            SourceError(source: .btm, message: "Hintergrund-Items nicht lesbar: Helper nicht erreichbar"),
        ])
    }
}

private struct UnavailableProvider: BTMDumpProviding {
    func dumpBTM() async throws -> String { throw BTMSourceError.helperUnavailable }
}

private struct FailingRunner: CommandRunning {
    let error: any Error
    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult { throw error }
}
