/// Beendet Prozesse anderer Benutzer über den root-Helper (#128). Wie bei `PrivilegedAutostartControlling` gilt:
/// Scheitert ein Aufruf nach dem Senden, ist das Ergebnis unbekannt – der `ProcessTerminator` prüft deshalb selbst, ob
/// der Prozess noch läuft.
public protocol PrivilegedProcessTerminating: Sendable {
    /// Sendet SIGTERM, mit `force` SIGKILL, sofern der Prozess noch derselbe ist (`executablePath`, `startTime` aus
    /// `RunningProcess`) und der Helper ihn beenden darf.
    ///
    /// - Throws: `HelperClientError.outdated` bei einem Helper vor Protokoll 4, `.rejected` mit der Meldung der
    ///   Helper-Prüfung, `.unavailable` ohne Verbindung.
    func terminateProcess(pid: Int32, executablePath: String, startTime: UInt64, force: Bool) async throws
}

extension HelperClient: PrivilegedProcessTerminating {}
