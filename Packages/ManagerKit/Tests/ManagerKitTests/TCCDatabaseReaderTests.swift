import Testing
import Foundation
@testable import ManagerKit

@Suite struct TCCDatabaseReaderTests {
    let reader = TCCDatabaseReader()

    @Test func readsRowsFromCurrentSchema() throws {
        let rows = try SQLiteFixture.withDatabase([
            SQLiteFixture.currentAccessSchema,
            SQLiteFixture.insert(service: "kTCCServiceSystemPolicyAllFiles", client: "/usr/libexec/sshd-keygen-wrapper",
                                 clientType: 1, lastModified: 1_790_000_100),
            SQLiteFixture.insert(service: "kTCCServiceCamera", client: "us.zoom.xos", lastModified: 1_790_000_000),
        ]) { try reader.readAccessRows(at: $0) }

        #expect(rows == [
            TCCRow(service: "kTCCServiceCamera", client: "us.zoom.xos", clientType: .bundleID, authValue: 2,
                   lastModified: Date(timeIntervalSince1970: 1_790_000_000), indirectObject: nil),
            TCCRow(service: "kTCCServiceSystemPolicyAllFiles", client: "/usr/libexec/sshd-keygen-wrapper", clientType: .path,
                   authValue: 2, lastModified: Date(timeIntervalSince1970: 1_790_000_100), indirectObject: nil),
        ])
    }

    @Test func toleratesMissingOptionalLastModified() throws {
        let rows = try SQLiteFixture.withDatabase([
            "CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER);",
            "INSERT INTO access VALUES ('kTCCServiceMicrophone', 'com.example', 0, 0);",
        ]) { try reader.readAccessRows(at: $0) }

        #expect(rows.count == 1)
        #expect(rows.first?.lastModified == Date(timeIntervalSince1970: 0))
        #expect(rows.first?.indirectObject == nil)
    }

    /// Automation: eine Zeile pro Ziel-App; `'UNUSED'`, leer und NULL bedeuten „kein Ziel“.
    @Test func readsIndirectObjectPerAutomationTarget() throws {
        let rows = try SQLiteFixture.withDatabase([
            SQLiteFixture.currentAccessSchema,
            SQLiteFixture.insert(service: "kTCCServiceAppleEvents", client: "com.tool", indirectObject: "com.apple.systemevents"),
            SQLiteFixture.insert(service: "kTCCServiceAppleEvents", client: "com.tool", indirectObject: "com.apple.finder"),
            SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.a"),
            SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.b", indirectObject: ""),
        ]) { try reader.readAccessRows(at: $0) }

        #expect(rows.map(\.indirectObject) == ["com.apple.finder", "com.apple.systemevents", nil, nil])
    }

    @Test func mapsNullIndirectObjectToNil() throws {
        let rows = try SQLiteFixture.withDatabase([
            "CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, indirect_object_identifier TEXT);",
            "INSERT INTO access VALUES ('kTCCServiceAppleEvents', 'com.tool', 0, 2, NULL);",
        ]) { try reader.readAccessRows(at: $0) }

        #expect(rows.map(\.indirectObject) == [nil])
    }

    @Test func reportsMissingRequiredColumns() throws {
        try SQLiteFixture.withDatabase(["CREATE TABLE access (service TEXT, client TEXT);"]) { path in
            #expect(throws: TCCReadError.missingColumns(["auth_value", "client_type"])) {
                try reader.readAccessRows(at: path)
            }
        }
    }

    @Test func reportsMissingAccessTableAsMissingColumns() throws {
        try SQLiteFixture.withDatabase(["CREATE TABLE other (x INTEGER);"]) { path in
            #expect(throws: TCCReadError.missingColumns(["auth_value", "client", "client_type", "service"])) {
                try reader.readAccessRows(at: path)
            }
        }
    }

    /// Ohne Festplattenvollzugriff schlägt bereits das Öffnen fehl – das muss als `cannotOpen` erkennbar sein.
    @Test func reportsUnreadableDatabaseAsCannotOpen() {
        #expect {
            try reader.readAccessRows(at: "/nonexistent/TCC.db")
        } throws: { error in
            if case .cannotOpen = error as? TCCReadError { true } else { false }
        }
    }

    @Test func unknownClientTypeFallsBackToShapeOfClient() throws {
        let rows = try SQLiteFixture.withDatabase([
            SQLiteFixture.currentAccessSchema,
            SQLiteFixture.insert(service: "kTCCServiceCamera", client: "/opt/tool", clientType: 7),
            SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.example.app", clientType: 7),
        ]) { try reader.readAccessRows(at: $0) }

        #expect(rows.map(\.clientType) == [.path, .bundleID])
    }

    /// NULL ist kein Bundle-ID-Typ `0`, sondern unbekannt – auch hier entscheidet die Form von `client`.
    @Test func nullClientTypeFallsBackToShapeOfClient() throws {
        let rows = try SQLiteFixture.withDatabase([
            "CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER);",
            "INSERT INTO access VALUES ('kTCCServiceCamera', '/opt/tool', NULL, 2);",
            "INSERT INTO access VALUES ('kTCCServiceCamera', 'com.example.app', NULL, 2);",
        ]) { try reader.readAccessRows(at: $0) }

        #expect(rows.map(\.clientType) == [.path, .bundleID])
    }

    /// `tccd` schreibt parallel: bestätigte, noch nicht zurückgeschriebene WAL-Einträge müssen sichtbar sein,
    /// offene Transaktionen dürfen nicht stören.
    @Test func seesCommittedWALFramesWhileWriterIsActive() throws {
        try SQLiteFixture.withDatabase([
            "PRAGMA journal_mode=WAL;",
            SQLiteFixture.currentAccessSchema,
        ]) { path in
            let writer = try SQLiteFixture.Connection(path: path)
            try writer.execute([
                "PRAGMA wal_autocheckpoint=0;",
                SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.committed"),
                "BEGIN IMMEDIATE;",
                SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.uncommitted"),
            ])

            let rows = try reader.readAccessRows(at: path)

            #expect(rows.map(\.client) == ["com.committed"])
        }
    }

    /// Das Verzeichnis der System-TCC.db ist für uns nicht beschreibbar; Lesen darf keine Schreibrechte brauchen.
    /// Voraussetzung: `-wal`/`-shm` existieren bereits (Apples SQLite behält sie nach dem Schließen, `tccd` ebenso).
    /// Fehlen sie bei einer WAL-Datenbank in einem schreibgeschützten Verzeichnis, meldet SQLite CANTOPEN.
    @Test func readsFromReadOnlyDirectory() throws {
        try SQLiteFixture.withDatabase([
            "PRAGMA journal_mode=WAL;",
            SQLiteFixture.currentAccessSchema,
            SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.example"),
        ]) { path in
            let directory = (path as NSString).deletingLastPathComponent
            let files = [path, path + "-wal", path + "-shm"].filter { FileManager.default.fileExists(atPath: $0) }
            defer {
                files.forEach { chmod($0, 0o644) }
                chmod(directory, 0o755)
            }
            files.forEach { chmod($0, 0o444) }
            chmod(directory, 0o555)

            let rows = try reader.readAccessRows(at: path)

            #expect(rows.map(\.client) == ["com.example"])
        }
    }

    /// Die System-TCC.db nutzt `journal_mode=delete`: Schreibt `tccd` gerade, wartet der Leser statt abzubrechen.
    @Test func waitsForWriterHoldingExclusiveLock() throws {
        try SQLiteFixture.withDatabase([
            SQLiteFixture.currentAccessSchema,
            SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.first"),
        ]) { path in
            let writer = try SQLiteFixture.Connection(path: path)
            try writer.execute(["BEGIN EXCLUSIVE;", SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.second")])
            // Eigener Thread statt globaler Dispatch-Queue: Deren Threads können unter Last (viele parallel laufende
            // Tests auf wenigen Kernen) länger als die 2 s Wartezeit des Lesers belegt sein.
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.1)
                try? writer.execute("COMMIT;")
            }

            let rows = try reader.readAccessRows(at: path)

            #expect(rows.map(\.client) == ["com.first", "com.second"])
        }
    }

    /// Eine dauerhaft gesperrte Datenbank ist ein Abfragefehler – kein Hinweis auf fehlenden Festplattenvollzugriff.
    @Test func reportsLockedDatabaseAsQueryFailure() throws {
        try SQLiteFixture.withDatabase([SQLiteFixture.currentAccessSchema]) { path in
            let writer = try SQLiteFixture.Connection(path: path)
            try writer.execute(["BEGIN EXCLUSIVE;", SQLiteFixture.insert(service: "kTCCServiceCamera", client: "com.x")])

            #expect {
                try TCCDatabaseReader(busyTimeout: .milliseconds(50)).readAccessRows(at: path)
            } throws: { error in
                if case .queryFailed = error as? TCCReadError { true } else { false }
            }
        }
    }
}
