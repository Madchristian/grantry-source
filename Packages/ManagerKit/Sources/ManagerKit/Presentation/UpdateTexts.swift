// Deutsche Texte des Update-Hinweises – gemeinsam für Übersicht, Menüleiste, Einstellungen, Onboarding und App-Menü.

import Foundation

public enum UpdateTexts {
    public static let availableTitle = "Update verfügbar"
    public static let download = "Laden …"
    public static let releaseNotes = "Was ist neu?"
    public static let checkDaily = "Täglich nach Updates suchen"
    public static let installHint = "Zum Installieren das DMG öffnen und Grantry in „Programme“ ziehen."

    public static func upToDate(_ version: String) -> String {
        "Grantry ist aktuell (\(version))."
    }

    public static func failed(_ reason: String) -> String {
        "Update-Prüfung fehlgeschlagen: \(reason)"
    }
}

extension AppcastItem {
    /// „Grantry <Version> ist verfügbar.“
    public var availabilityText: String {
        "Grantry \(version) ist verfügbar."
    }

    /// Der Feed nennt Release Notes („Was ist neu?“).
    public var hasReleaseNotes: Bool {
        releaseNotesURL != nil
    }
}
