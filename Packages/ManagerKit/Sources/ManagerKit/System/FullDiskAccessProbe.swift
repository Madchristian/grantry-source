import Foundation

/// Prüft, ob die App Festplattenvollzugriff hat: Das ist der Fall, wenn sich die System-TCC-Datenbank öffnen lässt.
public struct FullDiskAccessProbe: Sendable {
    /// *Datenschutz & Sicherheit › Festplattenvollzugriff* in den Systemeinstellungen.
    public static let settingsURL = PermissionCatalog.service(for: "kTCCServiceSystemPolicyAllFiles").settingsURL

    /// Datenbank, deren Lesbarkeit geprüft wird.
    public let databasePath: String
    private let reader: TCCDatabaseReader

    public init(databasePath: String = TCCDatabaseLocation.system.path, reader: TCCDatabaseReader = TCCDatabaseReader()) {
        self.databasePath = databasePath
        self.reader = reader
    }

    /// `true`, wenn die Datenbank geöffnet werden kann – auch wenn Schema oder Abfrage danach scheitern, denn der
    /// Zugriff selbst ist dann gewährt. Blockierende SQLite-Ein-/Ausgabe, daher außerhalb des Aufrufer-Actors.
    @concurrent
    public func hasFullDiskAccess() async -> Bool {
        do {
            _ = try reader.readAccessRows(at: databasePath)
            return true
        } catch .cannotOpen {
            return false
        } catch {
            return true
        }
    }
}
