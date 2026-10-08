import Foundation
import SQLite3

/// Eine Zeile der TCC-Tabelle `access`, noch ohne aufgelöste App.
public struct TCCRow: Hashable, Sendable {
    /// Art von `client`: Bundle-ID (`0`) oder absoluter Programmpfad (`1`).
    public enum ClientType: Int, Sendable {
        case bundleID = 0
        case path = 1

        /// Unbekannte Werte (künftige macOS-Versionen) und NULL (`rawValue == nil`) werden an der Form von `client`
        /// erkannt: Ein absoluter Pfad beginnt mit `/`, alles andere gilt als Bundle-ID.
        init(rawValue: Int?, client: String) {
            self = rawValue.flatMap(ClientType.init(rawValue:)) ?? (client.hasPrefix("/") ? .path : .bundleID)
        }
    }

    public let service: String
    public let client: String
    public let clientType: ClientType
    public let authValue: Int
    public let lastModified: Date
    /// Zielobjekt (`indirect_object_identifier`), etwa die gesteuerte App bei Automation; sonst `nil`.
    public let indirectObject: String?
}

public enum TCCReadError: LocalizedError, Equatable {
    /// Datenbank nicht zu öffnen oder zu lesen – typischerweise fehlender Festplattenvollzugriff.
    case cannotOpen(String)
    /// Der Tabelle `access` fehlen Pflichtspalten (alphabetisch sortiert) oder sie existiert nicht.
    case missingColumns([String])
    /// Sonstiger SQLite-Fehler, etwa eine dauerhaft gesperrte oder beschädigte Datenbank.
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let message): "TCC-Datenbank konnte nicht geöffnet werden: \(message)"
        case .missingColumns(let columns):
            "TCC-Datenbank hat ein unbekanntes Schema, es fehlen Spalten: \(columns.joined(separator: ", "))"
        case .queryFailed(let message): "TCC-Datenbank konnte nicht gelesen werden: \(message)"
        }
    }
}

/// Liest die Tabelle `access` nur lesend und toleriert Schema-Unterschiede zwischen macOS-Versionen.
///
/// Geöffnet wird mit `SQLITE_OPEN_READONLY` (nicht `immutable`), damit bestätigte, noch nicht zurückgeschriebene
/// WAL-Einträge sichtbar bleiben. Die System-TCC.db nutzt `journal_mode=delete`; hält `tccd` beim Schreiben eine
/// exklusive Sperre, wartet der Leser bis zu `busyTimeout`.
public struct TCCDatabaseReader: Sendable {
    static let requiredColumns = ["service", "client", "client_type", "auth_value"]

    private let busyTimeout: Duration

    public init(busyTimeout: Duration = .seconds(2)) {
        self.busyTimeout = busyTimeout
    }

    public func readAccessRows(at path: String) throws(TCCReadError) -> [TCCRow] {
        let db = try open(path)
        defer { sqlite3_close(db) }

        let columns = try columnNames(db)
        let missing = Self.requiredColumns.filter { !columns.contains($0) }.sorted()
        guard missing.isEmpty else { throw .missingColumns(missing) }

        let lastModified = Self.column("last_modified", in: columns, fallback: "0")
        let indirectObject = Self.column("indirect_object_identifier", in: columns, fallback: "NULL")
        // Fallbacks in ORDER BY müssen Nicht-Ganzzahl-Ausdrücke sein (etwa `NULL`):
        // Ein Ganzzahl-Literal wie `0` würde SQLite als Spaltenposition deuten.
        let sql = """
            SELECT service, client, client_type, auth_value, \(lastModified), \(indirectObject) FROM access
            ORDER BY service, client, client_type, \(indirectObject)
            """
        return try query(db, sql) { statement in
            let client = Self.text(statement, 1)
            return TCCRow(
                service: Self.text(statement, 0),
                client: client,
                clientType: TCCRow.ClientType(rawValue: Self.optionalInteger(statement, 2), client: client),
                authValue: Int(sqlite3_column_int64(statement, 3)),
                lastModified: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                indirectObject: Self.indirectObject(Self.text(statement, 5))
            )
        }
    }

    /// Optionale Spalten fehlen in älteren Schemata; dann liefert die Abfrage den Ausdruck `fallback`.
    private static func column(_ name: String, in columns: Set<String>, fallback: String) -> String {
        columns.contains(name) ? name : fallback
    }

    /// TCC markiert „kein Zielobjekt“ mit `'UNUSED'`; NULL und leer bedeuten dasselbe.
    private static func indirectObject(_ value: String) -> String? {
        value.isEmpty || value == "UNUSED" ? nil : value
    }

    private func open(_ path: String) throws(TCCReadError) -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw .cannotOpen(message)
        }
        sqlite3_busy_timeout(db, Int32(clamping: Int((busyTimeout / .milliseconds(1)).rounded())))
        return db
    }

    private func columnNames(_ db: OpaquePointer) throws(TCCReadError) -> Set<String> {
        Set(try query(db, "PRAGMA table_info(access)") { Self.text($0, 1) })
    }

    private func query<Row>(_ db: OpaquePointer, _ sql: String, map: (OpaquePointer) -> Row) throws(TCCReadError) -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.error(db)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(map(statement))
            case SQLITE_DONE: return rows
            default: throw Self.error(db)
            }
        }
    }

    /// Fehlende Zugriffsrechte zeigen sich je nach Lage beim Öffnen oder erst beim ersten Zugriff als CANTOPEN/AUTH/PERM.
    /// Achtung: Auch eine WAL-Datenbank ohne `-wal`/`-shm` in einem schreibgeschützten Verzeichnis meldet CANTOPEN.
    private static func error(_ db: OpaquePointer) -> TCCReadError {
        let message = String(cString: sqlite3_errmsg(db))
        switch sqlite3_errcode(db) {
        case SQLITE_CANTOPEN, SQLITE_AUTH, SQLITE_PERM: return .cannotOpen(message)
        default: return .queryFailed(message)
        }
    }

    private static func optionalInteger(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
}
