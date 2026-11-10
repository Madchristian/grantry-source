import Darwin

/// Prozesse, die der Task-Manager nie beendet und deren Priorität er nie ändert (Plan TM9, Schutzliste) – in der App
/// (eigene Prozesse: `loginwindow` läuft unter der UID des angemeldeten Benutzers) und im Helper. Schutz vor Versehen
/// (Abmeldung, Neustart, gesperrte Anmeldung), keine Grenze gegen einen Admin: Der kann per `sudo` ohnehin alles.
///
/// Verglichen wird der kanonische Programmpfad laut Kernel (`proc_pidpath` im `RunningProcess`), nie ein Name – ein
/// Programm, das sich `loginwindow` nennt, ist nicht geschützt, aber auch nicht das echte. Ein unlesbarer Pfad (`""`)
/// schützt nichts; PID 0 und 1 sind immer geschützt.
public struct ProtectedProcesses: Sendable {
    public struct Entry: Hashable, Sendable {
        public let name: String
        public let path: String
        /// Warum der Prozess geschützt ist (README, Doku).
        public let reason: String

        public init(name: String, path: String, reason: String) {
            self.name = name
            self.path = path
            self.reason = reason
        }
    }

    public let entries: [Entry]
    private let canonicalPaths: Set<String>

    public init(entries: [Entry]) {
        self.entries = entries
        canonicalPaths = Set(entries.map { FilePath.canonical($0.path) })
    }

    /// Ob `pid` mit dem Programm `executablePath` geschützt ist.
    public func protects(pid: pid_t, executablePath: String) -> Bool {
        pid <= 1 || (!executablePath.isEmpty && canonicalPaths.contains(FilePath.canonical(executablePath)))
    }

    /// Die Liste aus dem Helper-Entwurf (Plan TM9, Abschnitt „Schutzliste“).
    public static let system = ProtectedProcesses(entries: [
        Entry(name: "launchd", path: "/sbin/launchd", reason: "Beenden löst eine Kernel-Panik aus"),
        Entry(name: "WindowServer",
              path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
              reason: "alle Sitzungen enden, ungesicherte Daten gehen verloren"),
        Entry(name: "loginwindow", path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
              reason: "meldet ohne Sichern ab"),
        Entry(name: "logind", path: "/System/Library/CoreServices/logind", reason: "verwaltet die Sitzungen"),
        Entry(name: "opendirectoryd", path: "/usr/libexec/opendirectoryd",
              reason: "Benutzerkonten und Anmeldung, auch für die Kennwortabfrage"),
        Entry(name: "authd",
              path: "/System/Library/Frameworks/Security.framework/Versions/A/XPCServices/authd.xpc/Contents/MacOS/authd",
              reason: "prüft die Admin-Bestätigung selbst"),
        Entry(name: "securityd", path: "/usr/sbin/securityd", reason: "Schlüsselbund und Code-Signatur"),
        Entry(name: "securityd_system", path: "/usr/libexec/securityd_system", reason: "Schlüsselbund des Systems"),
        Entry(name: "coreauthd", path: "/System/Library/Frameworks/LocalAuthentication.framework/Support/coreauthd",
              reason: "Touch ID für die Kennwortabfrage"),
        Entry(name: "watchdogd", path: "/usr/libexec/watchdogd", reason: "Beenden löst einen Neustart aus"),
        Entry(name: "kernelmanagerd", path: "/usr/libexec/kernelmanagerd", reason: "lädt Kernel-Erweiterungen"),
        Entry(name: "configd", path: "/usr/libexec/configd", reason: "Netzwerk- und Systemkonfiguration"),
        Entry(name: "diskarbitrationd", path: "/usr/libexec/diskarbitrationd", reason: "Ein- und Aushängen von Laufwerken"),
        Entry(name: "notifyd", path: "/usr/sbin/notifyd", reason: "systemweite Benachrichtigungen, viele Dienste hängen"),
        Entry(name: "logd", path: "/usr/libexec/logd", reason: "Systemprotokoll, auch das des Helpers"),
        Entry(name: "syslogd", path: "/usr/sbin/syslogd", reason: "Systemprotokoll"),
        Entry(name: "syspolicyd", path: "/usr/libexec/syspolicyd", reason: "Gatekeeper"),
        Entry(name: "endpointsecurityd", path: "/usr/libexec/endpointsecurityd", reason: "Sicherheits-Erweiterungen"),
    ])
}
