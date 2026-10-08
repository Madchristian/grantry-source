import Foundation

/// Fest definierte Operationen des root-Helpers. Keine generische Befehlsausführung.
///
/// Antwort-Konvention: Der letzte Parameter jedes Reply-Blocks ist eine Fehlermeldung (`nil` = Erfolg);
/// `protocolVersion` hat keinen Fehlerparameter. Jede Eingabe wird im Helper mit `PrivilegedOperationPolicy`
/// geprüft.
///
/// `setEnabled`, `bootout` und `bootstrap` akzeptieren ausschließlich Plists, die direkt in
/// `/Library/LaunchDaemons` liegen, und wirken stets in der Domain `system`: Der Helper liest das Label
/// selbst aus der Plist (`PrivilegedOperationPolicy.launchDaemonLabel(forPlistAt:)`) statt es entgegen-
/// zunehmen, und nimmt keine Domain entgegen. Ein `com.apple.`-Präfix-Check auf dem Label allein würde
/// z. B. `org.cups.cupsd` übersehen; die Bindung an validierte Dateien in `/Library/LaunchDaemons` ist die
/// eigentliche Schranke. Vor jeder dieser Operationen klärt der Helper bei launchd
/// (`launchctl print system/<Label>`, `LaunchdServiceBinding`), ob unter dem Label genau diese Plist geladen
/// ist, und lehnt ab, wenn ein Dienst aus einer anderen Plist geladen ist (#99). LaunchAgents (Domain
/// `gui/<uid>`) verwaltet die App selbst – root darf keine fremden Benutzersitzungen antasten.
@objc public protocol GrantryHelperXPC {
    /// Protokollversion des Helpers (Gesundheitscheck, Versionsabgleich nach Updates).
    func protocolVersion(reply: @escaping @Sendable (Int) -> Void)
    /// Rohausgabe von `sfltool dumpbtm`.
    func dumpBTM(reply: @escaping @Sendable (String?, String?) -> Void)
    /// Lauschende Sockets aller Prozesse (`LibprocSocketEnumerator` als root), JSON-kodiertes `ListeningSocketScan`.
    /// Rein lesend, ohne Parameter; liefert nur Socket-Metadaten (Programmpfad, Benutzer, Adresse, Port, Elternkette).
    func listListeningSockets(reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Beendet einen Prozess (#128, „Prozess beenden …“): SIGTERM, mit `force` SIGKILL. Der Helper prüft selbst mit
    /// `ProcessTerminationPolicy.helper()` statt `PrivilegedOperationPolicy`: PID > 1, weder Helper noch Aufrufer,
    /// Programm nicht im Grantry-Bundle, Programmpfad unverändert `executablePath`, Startzeit unverändert `startTime`
    /// (`RunningProcess.startTime`, gegen PID-Wiederverwendung), nicht Apple-signiert (auch keine Interpreter); danach
    /// bestätigt er die Identität erneut und sendet an die bestätigte Prozessgeneration (`ProcessAuditToken`). Ohne
    /// feststellbaren Aufrufer lehnt er ab, ebenso einen Auftrag, der bis zum Signal länger als
    /// `HelperService.terminationRequestLifetime` gebraucht hat (Wartezeit samt Prüfung). Ein bereits beendeter Prozess
    /// ist Erfolg. Keine weiteren Eingaben.
    func terminateProcess(
        pid: Int32, executablePath: String, startTime: UInt64, force: Bool, reply: @escaping @Sendable (String?) -> Void
    )
    /// `launchctl enable|disable system/<Label>`; `plistPath` muss direkt in `/Library/LaunchDaemons` liegen. Der
    /// Override gilt in launchd je Label; trägt eine weitere Plist der Domain `system` dasselbe Label, lehnt der
    /// Helper ab (`PolicyViolation.ambiguousLabel`).
    func setEnabled(plistPath: String, enabled: Bool, reply: @escaping @Sendable (String?) -> Void)
    /// `launchctl bootout system <plistPath>`, nur wenn launchd den Dienst laut vorheriger Abfrage aus dieser Plist
    /// geladen hat; ein nicht geladener Dienst ist Erfolg ohne Befehl. `plistPath` muss direkt in
    /// `/Library/LaunchDaemons` liegen.
    func bootout(plistPath: String, reply: @escaping @Sendable (String?) -> Void)
    /// `launchctl bootstrap system <plistPath>`; ein bereits aus dieser Plist geladener Dienst ist Erfolg ohne
    /// Befehl. `plistPath` muss direkt in `/Library/LaunchDaemons` liegen.
    func bootstrap(plistPath: String, reply: @escaping @Sendable (String?) -> Void)
    /// Entlädt (nur LaunchDaemons), sichert und löscht eine Plist in einem eingereihten Ablauf (#166). Antwort:
    /// Backup-Pfad und ob der Helper den Dienst entladen hat.
    ///
    /// `expectedFingerprint` ist der JSON-kodierte `FileFingerprint` aus dem Scan der App (`nil`: unbekannt, etwa aus
    /// älteren Snapshots); ein nicht dekodierbarer wird abgelehnt. Für eine Plist direkt in `/Library/LaunchDaemons`
    /// fragt der Helper zuerst launchd (`launchctl print system/<Label>`) und sichert **danach, unmittelbar vor dem
    /// `bootout`**, nur eine Datei mit genau diesem Fingerabdruck (`PlistBackupStore.backupForRemoval(_:expecting:)`):
    /// Ein Austausch während der Abfrage wird abgelehnt, bevor etwas entladen wird. Entladen wird nur ein aus genau
    /// dieser Plist geladener Dienst (`bootout system <plist>`); ein nicht oder aus einer anderen Plist geladener
    /// bleibt unberührt, gelöscht wird dann nur die Datei. Gelöscht wird nur, wenn unmittelbar davor noch dasselbe
    /// Dateiobjekt mit demselben Inhalt wie die Sicherung vorliegt (#156); sonst bleibt die Datei, die Sicherung
    /// ebenso. Scheitert das Löschen nach einem `bootout`, lädt der Helper den Dienst nur dann wieder, wenn am Pfad noch
    /// genau die gesicherten Bytes liegen (`ServiceReload`; eine Ersatzkonfiguration nie), und meldet
    /// `UnloadedRemovalFailure`.
    /// Plists in `/Library/LaunchAgents` werden nur gesichert und gelöscht (entladen muss sie die App in `gui/<uid>`).
    func unloadAndRemovePlist(
        path: String, expectedFingerprint: Data?, reply: @escaping @Sendable (String?, Bool, String?) -> Void
    )
    /// Stellt ein System-Backup wieder her. Antwort: wiederhergestellter Pfad.
    func restorePlist(backupPath: String, reply: @escaping @Sendable (String?, String?) -> Void)

    // Absichern (Spec v2): parameterlos, feste Kommandozeilen aus `SecurityHardening`; es gibt kein Gegenstück
    // zum Abschalten.

    /// `socketfilterfw --setglobalstate on` – nur wenn `--getglobalstate` „aus“ meldet; „Alle eingehenden
    /// blockieren“ bleibt so unberührt.
    func enableFirewall(reply: @escaping @Sendable (String?) -> Void)
    /// `socketfilterfw --setstealthmode on` – nur wenn `--getstealthmode` „aus“ meldet.
    func enableStealthMode(reply: @escaping @Sendable (String?) -> Void)
    /// `spctl --global-enable` – nur wenn `spctl --status` „assessments disabled“ meldet.
    func enableGatekeeper(reply: @escaping @Sendable (String?) -> Void)
    /// Setzt die Schlüssel aus `SoftwareUpdateKey` per `defaults write … -bool true`.
    func enableAutomaticUpdates(reply: @escaping @Sendable (String?) -> Void)
    /// `xprotect update`.
    func updateXProtect(reply: @escaping @Sendable (String?) -> Void)
}

/// Fabrik für das `NSXPCInterface` des Helper-Protokolls sowie dessen Versionsstand.
public enum HelperXPC {
    /// Bei inkompatiblen Protokolländerungen erhöhen. 2: Absichern (v2 Sicherheitsstatus). 3: lauschende Sockets (#128).
    /// 4: Prozess beenden (#128). 5: Sockets mit Startzeit des Besitzers, Signal an die Prozessgeneration, Ablauffrist
    /// des Beenden-Auftrags (#153). 6: Sockets mit Herkunft des Ports (`hasSystemAssignedPort`, #154). 7: `removePlist`
    /// mit dem Fingerabdruck der Plist aus dem Scan (#156). 8: `unloadAndRemovePlist` statt `removePlist` – Entladen,
    /// Fingerabdruckprüfung vor dem `bootout`, Löschen und Rollback in einem Helper-Ablauf (#166).
    public static let protocolVersion = 8

    /// Kleinste Protokollversion mit `listListeningSockets`. Der Client prüft hier `>=`, nicht `==` wie
    /// `HelperManager` und `SecurityActions`: Ein rein lesender Aufruf funktioniert auch mit einem neueren Helper, der
    /// ihn weiterhin anbietet; die Gleichheit verlangen nur Zustandsanzeige und verändernde Aktionen.
    public static let listeningSocketsMinimumVersion = 3

    /// Kleinste Protokollversion mit `terminateProcess`; der Client prüft wie bei `listeningSocketsMinimumVersion`
    /// mit `>=`. Die Gleichheit für verändernde Aktionen verlangt die App über den Helper-Zustand `.ready`
    /// (`ListenerTerminationPolicy`).
    public static let terminateProcessMinimumVersion = 4

    /// Kleinste Protokollversion mit `unloadAndRemovePlist`; der Client prüft mit `>=` und meldet einem älteren Helper
    /// verständlich „veraltet“, statt ihn mit einer unbekannten Nachricht scheitern zu lassen.
    public static let unloadAndRemovePlistMinimumVersion = 8

    /// Erstellt das `NSXPCInterface` für `GrantryHelperXPC`.
    public static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: GrantryHelperXPC.self)
    }
}
