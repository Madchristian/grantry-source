import Foundation
import SQLite3
import TestSupport

/// Temporäre SQLite-Datenbanken als Fixture für den TCC-Leser.
enum SQLiteFixture {
    /// Schema der Tabelle `access`, wie es macOS 27 verwendet (aus `/Library/Application Support/com.apple.TCC/TCC.db`).
    static let currentAccessSchema = """
    CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
      auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL,
      csreq BLOB, policy_id INTEGER, indirect_object_identifier_type INTEGER,
      indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB,
      flags INTEGER, last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
      pid INTEGER, pid_version INTEGER, boot_uuid TEXT NOT NULL DEFAULT 'UNUSED',
      last_reminded INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
      one_time_reprompt_eligible INTEGER, reminder_count INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (service, client, client_type, indirect_object_identifier));
    """

    /// Legt `TCC.db` in einem frischen Scratch-Verzeichnis an, führt `statements` aus und übergibt den Pfad an `body`.
    /// Das Verzeichnis wird anschließend samt Datenbank (und `-wal`/`-shm`) entfernt.
    @discardableResult
    static func withDatabase<T>(_ statements: [String], _ body: (String) throws -> T) throws -> T {
        try ScratchDirectory.with(prefix: "tcc") { directory in
            let path = directory.appending(path: "TCC.db").path
            try Connection(path: path).execute(statements)
            return try body(path)
        }
    }

    /// Asynchrone Variante von `withDatabase(_:_:)`.
    @discardableResult
    static func withDatabase<T>(_ statements: [String], _ body: (String) async throws -> T) async throws -> T {
        try await ScratchDirectory.with(prefix: "tcc") { directory in
            let path = directory.appending(path: "TCC.db").path
            try Connection(path: path).execute(statements)
            return try await body(path)
        }
    }

    /// Schreibende Verbindung, etwa um einen parallel schreibenden `tccd` nachzustellen. Schließt sich bei `deinit`.
    /// `@unchecked Sendable`: Die System-SQLite läuft im Multi-Thread-Modus (`sqlite3_threadsafe() == 2`); erst
    /// `SQLITE_OPEN_FULLMUTEX` macht diese Verbindung „serialized“ und damit von mehreren Threads aus nutzbar.
    final class Connection: @unchecked Sendable {
        private let handle: OpaquePointer

        init(path: String) throws {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
                sqlite3_close(handle)
                throw FixtureError.open(path)
            }
            self.handle = handle
        }

        deinit { sqlite3_close(handle) }

        func execute(_ statements: [String]) throws {
            for sql in statements {
                guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                    throw FixtureError.exec(String(cString: sqlite3_errmsg(handle)))
                }
            }
        }

        func execute(_ sql: String) throws {
            try execute([sql])
        }
    }

    /// Erzeugt eine `INSERT`-Anweisung für die Pflichtspalten des aktuellen Schemas.
    /// `indirectObject` hat wie in TCC den Standardwert `'UNUSED'`.
    /// Nur für Tests: Die Werte werden unmaskiert in das SQL eingesetzt und dürfen keine `'` enthalten.
    static func insert(
        service: String, client: String, clientType: Int = 0, authValue: Int = 2, lastModified: Int = 1_790_000_000,
        indirectObject: String = "UNUSED"
    ) -> String {
        """
        INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, last_modified, \
        indirect_object_identifier) \
        VALUES ('\(service)', '\(client)', \(clientType), \(authValue), 2, 1, \(lastModified), '\(indirectObject)');
        """
    }

    enum FixtureError: Error { case open(String), exec(String) }
}
