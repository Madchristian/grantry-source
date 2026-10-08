/// Ob eine verändernde Aktion für einen Eintrag angeboten wird.
public enum ActionAvailability: Hashable, Sendable {
    case available
    case readOnly(Reason)

    /// Grund, warum ein Eintrag nur lesbar ist.
    public enum Reason: Hashable, Sendable, CustomStringConvertible {
        case appleComponent
        /// App fehlt nachweislich (`missing`) oder vermutlich (`probablyMissing`).
        case notInstalled
        /// Ob die App existiert, ließ sich nicht feststellen (`Presence.unknown`).
        case presenceUnknown
        case noBundleIdentifier
        /// Kein einzelner TCC-Dienst (etwa `All`): Ein Zurücksetzen für alle Apps träfe mehr als diesen Dienst.
        case noSingleService
        case managedBySystemSettings
        case noPlist
        /// LaunchAgent, der per `LimitLoadToSessionType` nur außerhalb der Aqua-Sitzung läuft (z. B. `Background`,
        /// `LoginWindow`): In `gui/<uid>` nie geladen, launchctl-Aktionen dort scheitern oder wirken nicht.
        case nonAquaSession
        /// Systemweiter Eintrag (`/Library/Launch*`) mit `com.apple.`-Label, der keine Apple-Komponente ist (Tarnung):
        /// Dateien und LaunchDaemons ändert der Helper, und der lehnt Apple-Labels grundsätzlich ab.
        case appleLabelInSystemDomain
        /// Unter dem Label des Eintrags ist in `gui/<uid>` ein Dienst aus einer anderen Plist geladen (Label-Kollision,
        /// etwa ein als Apple getarnter Agent neben dem echten Apple-Dienst). Label-basierte launchctl-Befehle träfen
        /// diesen Dienst; erkannt erst beim Ausführen der Aktion (`AutostartActions`), nicht von der `ActionPolicy`.
        case conflictingService
        /// Eine weitere Plist derselben launchd-Domain trägt das Label des Eintrags (#138): Der Override
        /// (`launchctl enable|disable`) gilt in launchd je Label und schaltete sie mit um. Erkannt erst beim Ausführen
        /// (`AutostartActions.setEnabled`); für LaunchDaemons prüft das der Helper (#99).
        case ambiguousLabel
        /// Die Plist des Eintrags ist seit dem Scan ersetzt oder umgeschrieben worden (`AutostartItem.plistFingerprint`,
        /// #156): Entfernen träfe einen anderen Eintrag. Erkannt erst beim Ausführen (`AutostartActions.remove`).
        case plistChanged
        /// Nur fortgeschriebener Eintrag (`AutostartItem.lastVerifiedAt`, #139): Seine Plist war beim letzten Scan nicht
        /// auswertbar, die Angaben stammen aus einem älteren Scan.
        case outdatedState
        /// Verwaltete Agenten-Konfiguration (`AgentScope.system`) – nur lesbar.
        case managedConfiguration
        /// Agenten-Konfiguration außerhalb des Benutzerordners.
        case configurationOutsideHome
        /// Agenten-Konfiguration, die Grantrys Katalog nicht beschreibt.
        case unknownConfiguration
        /// Programm im eigenen Bundle (App oder Helper): „Prozess beenden …“ trifft Grantry nie.
        case ownProcess
        /// Prozess eines anderen Benutzers, aber der Helper ist nicht bereit.
        case helperRequired
        /// Apple-signiertes Programm eines anderen Benutzers: Der Helper beendet keine Apple-Programme.
        case foreignAppleProgram

        public var description: String {
            switch self {
            case .appleComponent: "Apple-Komponenten sind schreibgeschützt"
            case .notInstalled: "App ist nicht mehr installiert – einzeln nicht zurücksetzbar"
            case .presenceUnknown: "Existenz der App nicht feststellbar – Zurücksetzen nicht möglich"
            case .noBundleIdentifier: "tccutil unterstützt nur Apps mit Bundle-ID"
            case .noSingleService: "Nur einzelne Datenschutz-Dienste lassen sich für alle Apps zurücksetzen"
            case .managedBySystemSettings: "Wird in den Systemeinstellungen unter „Anmeldeobjekte“ verwaltet"
            case .noPlist: "Keine launchd-Plist bekannt"
            case .nonAquaSession: "Läuft nicht in der Benutzersitzung – Änderung hier nicht möglich"
            case .appleLabelInSystemDomain: "Systemweiter Eintrag mit Apple-Label – nur manuell entfernbar"
            case .conflictingService: "Ein gleichnamiger Dienst aus einer anderen Datei ist geladen – Aktion abgebrochen"
            case .ambiguousLabel:
                "Eine andere Plist trägt dasselbe Label – Aktivieren/Deaktivieren träfe beide, Aktion abgebrochen"
            case .plistChanged: "Die Datei hat sich seit dem letzten Scan geändert – Aktion abgebrochen, bitte neu scannen"
            case .outdatedState: "Plist zuletzt nicht auswertbar – Änderung erst nach erneutem Lesen möglich"
            case .managedConfiguration: "Verwaltete Konfiguration – nur lesbar"
            case .configurationOutsideHome: "Datei liegt außerhalb deines Benutzerordners – bitte im Editor ändern"
            case .unknownConfiguration: "Datei ist Grantry nicht bekannt – bitte im Editor ändern"
            case .ownProcess: "Grantry beendet sich nicht selbst"
            case .helperRequired: ProcessTerminationError.helperRequired.errorDescription ?? ""
            case .foreignAppleProgram: "Apple-Programme anderer Benutzer beendet Grantry nicht"
            }
        }
    }
}

/// Regeln aus Spec §5, wer welche Einträge verändern darf: Apple-Einträge sind nur lesbar; `tccutil` braucht
/// installierte Apps, deren TCC-Client-ID die Bundle-ID ist; Login-/Hintergrund-Items (BTM) werden in den
/// Systemeinstellungen verwaltet.
///
/// Apple-Einträge erkennt `AppleComponent.contains(_:)` – ein `com.apple.`-Label oder Apple-Eigentümer zählt dort
/// nicht, wenn es nachweislich Tarnung ist (Plist außerhalb der Apple-Pfade; Programm geprüft und nicht von Apple
/// signiert oder ein Interpreter mit Argumenten).
/// Solche Einträge im Benutzerordner lassen sich ändern und entfernen; systemweite bleiben gesperrt
/// (`appleLabelInSystemDomain`), weil der Helper Apple-Labels grundsätzlich ablehnt.
public struct ActionPolicy: Sendable {
    /// Session-Typ der grafischen Benutzersitzung (`gui/<uid>`).
    static let aquaSession = "Aqua"

    public init() {}

    /// Ob sich eine Datenschutz-Berechtigung per `tccutil` zurücksetzen lässt.
    public func availability(for grant: PermissionGrant) -> ActionAvailability {
        if AppleComponent.contains(grant) { return .readOnly(.appleComponent) }
        // `tccutil reset` wirkt auf die TCC-Zeile mit dieser Bundle-ID. Ein Pfad-Client (roher `clientID` ist ein Pfad),
        // dessen `.app` sich zu einer Bundle-ID auflösen lässt, hat eine andere Zeile – ein Reset per Bundle-ID würde
        // sie nicht treffen und trotzdem Erfolg melden.
        guard let bundleID = grant.client.bundleID, grant.clientID == bundleID else { return .readOnly(.noBundleIdentifier) }
        switch grant.client.presence {
        case .present: return .available
        case .missing, .probablyMissing: return .readOnly(.notInstalled)
        case .unknown: return .readOnly(.presenceUnknown)
        }
    }

    /// Ob sich ein Autostart-Eintrag verändern lässt (aktivieren/deaktivieren/entfernen/wiederherstellen).
    public func availability(for item: AutostartItem) -> ActionAvailability {
        if AppleComponent.contains(item) { return .readOnly(.appleComponent) }
        guard item.kind == .launchAgent || item.kind == .launchDaemon else { return .readOnly(.managedBySystemSettings) }
        guard item.plistPath != nil else { return .readOnly(.noPlist) }
        guard item.isCurrent else { return .readOnly(.outdatedState) }
        if item.domain == .system, AppleIdentifier.matches(item.label) { return .readOnly(.appleLabelInSystemDomain) }
        if item.kind == .launchAgent, let sessionTypes = item.sessionTypes, !sessionTypes.contains(Self.aquaSession) {
            return .readOnly(.nonAquaSession)
        }
        return .available
    }
}
