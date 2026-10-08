/// Privilegierte Autostart-Operationen, die der root-Helper ausführt.
///
/// launchctl-Operationen wirken nur auf Plists direkt in `/Library/LaunchDaemons` (Domain `system`); das Label
/// liest der Helper selbst aus der Datei. Datei-Operationen gelten für `/Library/LaunchAgents` und
/// `/Library/LaunchDaemons`.
///
/// Abbruch und Zeitüberschreitung: Endet ein Aufruf mit `CancellationError` oder einem Verbindungsfehler, **nachdem**
/// die Anfrage gesendet wurde, ist das Ergebnis unbekannt – der Helper kann die Operation trotzdem noch ausführen.
/// Aufrufer (z. B. `AutostartActions`) dürfen dann nicht annehmen, dass sich nichts geändert hat, sondern sollten
/// den Zustand neu einlesen. Vor dem Senden abgebrochene Aufrufe erreichen den Helper nicht.
public protocol PrivilegedAutostartControlling: Sendable {
    /// Protokollversion des Helpers; Vorbedingung, bevor die App selbst etwas verändert, das ein Helper-Aufruf
    /// abschließen muss.
    func protocolVersion() async throws -> Int
    /// `launchctl enable|disable system/<Label>` für den LaunchDaemon unter `plistPath`.
    func setEnabled(plistPath: String, enabled: Bool) async throws
    /// `launchctl bootout system/<Label>` für den LaunchDaemon unter `plistPath`.
    func bootout(plistPath: String) async throws
    /// `launchctl bootstrap system <plistPath>`.
    func bootstrap(plistPath: String) async throws
    /// Entlädt (nur LaunchDaemons in `/Library/LaunchDaemons`), sichert und löscht die Plist in einem Helper-Ablauf
    /// (#166): gesichert wird nach der launchd-Abfrage und unmittelbar vor dem `bootout` nur eine Datei, die noch
    /// `expectedFingerprint` (aus dem Scan; `nil`: unbekannt) trägt, gelöscht nur, wenn sie bis dahin dasselbe
    /// Dateiobjekt mit demselben Inhalt wie die Sicherung bleibt. Scheitert das Löschen nach dem `bootout`, lädt der
    /// Helper den Dienst wieder und meldet das (`UnloadedRemovalFailure`).
    func unloadAndRemovePlist(path: String, expectedFingerprint: FileFingerprint?) async throws -> PrivilegedPlistRemoval
    /// Stellt ein System-Backup wieder her.
    /// - Returns: wiederhergestellter Pfad.
    func restorePlist(backupPath: String) async throws -> String
}

/// Ergebnis von `PrivilegedAutostartControlling.unloadAndRemovePlist(path:expectedFingerprint:)`.
public struct PrivilegedPlistRemoval: Equatable, Sendable {
    /// Pfad der Sicherung im System-Speicher des Helpers.
    public let backupPath: String
    /// Ob der Helper den Dienst vor dem Löschen entladen hat (nur aus genau dieser Plist geladene LaunchDaemons).
    public let wasUnloaded: Bool

    public init(backupPath: String, wasUnloaded: Bool) {
        self.backupPath = backupPath
        self.wasUnloaded = wasUnloaded
    }
}
