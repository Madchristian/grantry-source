import Foundation

// Deutsche Texte und Farben für Autostart-Einträge in Liste und Detailansicht (Spec §6: Status-Badges
// aktiv/deaktiviert/geladen).

/// Zustands-Badge eines Autostart-Eintrags.
public enum AutostartStatus: Hashable, Sendable {
    case enabled, disabled, loaded, notLoaded
    /// Nur fortgeschrieben: Die Plist war beim letzten Scan nicht auswertbar (`AutostartItem.lastVerifiedAt`, #139).
    case outdated

    /// Deutsche Kurzbeschriftung.
    public var title: String {
        switch self {
        case .enabled: "aktiv"
        case .disabled: "deaktiviert"
        case .loaded: "geladen"
        case .notLoaded: "nicht geladen"
        case .outdated: "alter Stand"
        }
    }

    /// Grün für aktiv, sonst neutral – ein nicht geladener Eintrag ist kein Fehler (z. B. `RunAtLoad` fehlt). Ein alter
    /// Stand ist ein Hinweis: Die Angaben sind nicht geprüft.
    public var tone: PresentationTone {
        switch self {
        case .enabled: .positive
        case .disabled, .loaded, .notLoaded: .neutral
        case .outdated: .warning
        }
    }
}

extension AutostartItem {
    /// Status-Badges: immer aktiv/deaktiviert, dazu der Ladezustand, wenn die Quelle ihn kennt, und „alter Stand“ für
    /// fortgeschriebene Einträge.
    public var statusBadges: [AutostartStatus] {
        [isEnabled ? .enabled : .disabled] + (isLoaded.map { [$0 ? .loaded : .notLoaded] } ?? [])
            + (isCurrent ? [] : [.outdated])
    }

    /// Hinweis für fortgeschriebene Einträge (#139): „Plist zuletzt nicht auswertbar – Stand von vor 3 Tagen“; `nil`,
    /// wenn der Eintrag aus dem aktuellen Scan stammt.
    /// - Parameter calendar: Kalender für die Tagesangabe (`CalendarDays`).
    public func verificationNote(now: Date, calendar: Calendar = .current) -> String? {
        lastVerifiedAt.map { verifiedAt in
            "Plist zuletzt nicht auswertbar – Stand von " + SecurityCheckPresentation.dayText(
                CalendarDays.since(verifiedAt, now: now, calendar: calendar), .ago
            )
        }
    }

    /// Befehl für die Detailansicht (`commandLine`, #137) – nur, wenn er mehr zeigt als das Programm, also Argumente ab
    /// `argv[1]` hat.
    public var displayedCommandLine: String? {
        (programArguments?.count ?? 0) > 1 ? commandLine : nil
    }

    /// In den Argumenten wurde etwas maskiert (dann gibt es einen Fingerabdruck der Rohwerte).
    public var hasMaskedArguments: Bool { programArgumentsFingerprint != nil }

    /// Hinweis zum angezeigten Befehl (`MaskedCommandNote`): verborgenes Skript oder maskierte Werte; sonst `nil`.
    public var commandNote: String? {
        MaskedCommandNote.text(for: programArguments ?? [], program: program, isMasked: hasMaskedArguments, hasHiddenScript: hasHiddenScript)
    }
}

extension AutostartDomain {
    /// „Benutzer“ bzw. „System“ (wie `TCCScope`).
    public var displayName: String {
        switch self {
        case .user: "Benutzer"
        case .system: "System"
        }
    }
}

extension ActionAvailability.Reason {
    /// Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen.
    public static let loginItemsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    /// Seite der Systemeinstellungen, auf der sich ein so geschützter Eintrag stattdessen ändern lässt.
    public var settingsURL: URL? {
        self == .managedBySystemSettings ? Self.loginItemsSettingsURL : nil
    }
}

extension ActionOutcomePresentation {
    /// Ergebnis von `ActionCoordinator.setEnabled(_:_:)`.
    public static func setEnabled(_ item: AutostartItem, _ enabled: Bool, outcome: ActionOutcome) -> ActionOutcomePresentation {
        ActionOutcomePresentation(outcome, successMessage: "„\(item.label)“ wurde \(enabled ? "aktiviert" : "deaktiviert").")
    }

    /// Ergebnis von `ActionCoordinator.remove(_:)`.
    public static func remove(_ item: AutostartItem, outcome: ActionOutcome) -> ActionOutcomePresentation {
        ActionOutcomePresentation(
            outcome, successMessage: "„\(item.label)“ wurde entfernt. Wiederherstellen ist im Verlauf möglich."
        )
    }
}
