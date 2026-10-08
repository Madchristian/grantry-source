import Foundation

/// Eine Zeile im Bereich „Sicherheit“: Ampel (Farbe **und** Symbol/Text), Klartext, Details und Angebote.
public struct SecurityCheckPresentation: Hashable, Sendable, Identifiable {
    public enum Offer: Hashable, Sendable {
        /// Aktion über den `ActionRunner`; freigeben nur, wenn `SecurityOverview.isAvailable(_:helperState:)`.
        case action(SecurityAction, title: String)
        case link(title: String, url: URL)
    }

    /// `SecurityCheck.id` (für Fokus und `ActionRunner.runningRecordID`).
    public let id: String
    public let kind: SecurityCheckKind
    public let title: String
    public let statusText: String
    public let tone: PresentationTone
    public let systemImage: String
    public let summary: String
    /// Was zu tun ist, wenn Grantry es nicht selbst kann (SIP); sonst `nil`.
    public let explanation: String?
    public let details: [String]
    public let offers: [Offer]
    /// VoiceOver: „Titel: Status. Klartext“.
    public var accessibilityLabel: String { "\(title): \(statusText). \(summary)" }

    /// - Parameter calendar: Kalender für Tagesangaben; wie bei `SecurityPolicy.calendar`.
    public init(_ check: SecurityCheck, now: Date, calendar: Calendar = .current) {
        id = check.id
        kind = check.kind
        title = check.kind.displayName
        let content = Self.content(for: check, days: { CalendarDays.since($0, now: now, calendar: calendar) })
        (summary, explanation, details, offers) = (content.summary, content.explanation, content.details, content.offers)
        (statusText, tone) = Self.status(of: check)
        systemImage = check.state == .unknown ? "questionmark.circle.fill" : tone.systemImage
    }

    /// MDM angemeldet bleibt `.good` (Spec), wird aber neutral als „Angemeldet“ gezeigt (Plan-Abweichung 10).
    private static func status(of check: SecurityCheck) -> (String, PresentationTone) {
        if check.state != .unknown, case .mdmEnrollment(true, _)? = check.facts { return ("Angemeldet", .neutral) }
        return (check.state.statusTitle, check.state.tone)
    }

    private struct Content {
        var summary: String
        var explanation: String? = nil
        var details: [String] = []
        var offers: [Offer] = []
    }

    /// „Jetzt suchen“ läuft als Nutzer ohne Helper – auch, wenn die Prüfung selbst fehlschlug.
    private static let searchOffer = Offer.action(.checkForUpdates, title: "Jetzt suchen")

    /// - Parameter days: Kalendertage seit einem Datum (`CalendarDays`).
    private static func content(for check: SecurityCheck, days: (Date) -> Int) -> Content {
        // Bei `unknown` sind Fakten höchstens fortgeschrieben – angezeigt wird der Fehler.
        guard check.state != .unknown, let facts = check.facts else {
            return Content(
                summary: "Konnte nicht geprüft werden: \(check.detail ?? "unbekannter Fehler")",
                details: check.lastKnownState.map { ["Zuletzt bekannt: \($0.displayName)"] } ?? [],
                offers: check.kind == .pendingUpdates ? [searchOffer] : []
            )
        }
        switch facts {
        case .fileVault(let status):
            let summary = switch status {
            case .on: "FileVault ist eingeschaltet – die Festplatte ist verschlüsselt."
            case .encrypting: "FileVault verschlüsselt gerade die Festplatte."
            case .decrypting: "FileVault entschlüsselt gerade die Festplatte."
            case .pendingRestart: "FileVault wird nach dem nächsten Neustart eingeschaltet."
            case .off: "FileVault ist ausgeschaltet – die Daten auf der Festplatte sind nicht verschlüsselt."
            }
            return Content(summary: summary, offers: status == .on ? [] : link("Datenschutz & Sicherheit öffnen", SecuritySettingsLinks.fileVault))
        case .firewall(let enabled, let stealthMode):
            let summary = !enabled ? "Die Firewall ist ausgeschaltet."
                : stealthMode ? "Firewall und Tarnmodus sind eingeschaltet."
                : "Firewall an, Tarnmodus aus – der Mac antwortet auf Anfragen wie Ping."
            return Content(summary: summary, offers:
                (enabled ? [] : [.action(.enableFirewall, title: "Firewall einschalten")])
                + (stealthMode ? [] : [.action(.enableStealthMode, title: "Tarnmodus einschalten")]))
        case .sip(let status):
            let summary = switch status {
            case .enabled: "Der Systemintegritätsschutz ist aktiv."
            case .customConfiguration: "Der Systemintegritätsschutz ist nur teilweise aktiv (angepasste Konfiguration)."
            case .disabled: "Der Systemintegritätsschutz ist ausgeschaltet."
            }
            return Content(summary: summary, explanation: status == .enabled ? nil
                : "Einschalten geht nur im Wiederherstellungsmodus: Mac im Wiederherstellungsmodus starten, Terminal öffnen, „csrutil enable“ ausführen und neu starten.")
        case .gatekeeper(let enabled):
            return enabled
                ? Content(summary: "Gatekeeper prüft Apps vor dem ersten Öffnen.")
                : Content(summary: "Gatekeeper ist ausgeschaltet – Apps aus beliebigen Quellen öffnen sich ohne Prüfung.",
                          offers: [.action(.enableGatekeeper, title: "Gatekeeper einschalten")])
        case .xprotect(let version, let installedAt):
            return Content(summary: "Version \(version), installiert \(dayText(days(installedAt), .ago)).",
                           offers: [.action(.updateXProtect, title: "XProtect aktualisieren")])
        case .automaticUpdates(let disabled):
            guard !disabled.isEmpty else { return Content(summary: "Automatische Updates sind vollständig eingeschaltet.") }
            let names = SoftwareUpdateKey.allCases.filter(disabled.contains).map(\.displayName).joined(separator: ", ")
            return Content(summary: "Ausgeschaltet: \(names).", offers: [.action(.enableAutomaticUpdates, title: "Automatische Updates einschalten")])
        case .pendingUpdates(let updates, let lastCheck):
            let summary = switch updates.count {
            case 0: "Keine Updates ausstehend."
            case 1: "1 Update ausstehend."
            default: "\(updates.count) Updates ausstehend."
            }
            let lines = updates.map { "\($0.displayTitle) – \(dayText(days($0.firstSeenAt), .since))" }
                + ["Letzte Suche: " + (lastCheck.map { dayText(days($0), .ago) } ?? "noch nie")]
            return Content(summary: summary, details: lines, offers: [searchOffer]
                + (updates.isEmpty ? [] : link("Softwareupdate öffnen", SecuritySettingsLinks.softwareUpdate)))
        case .mdmEnrollment(let enrolled, let viaDEP):
            return Content(summary: enrolled
                ? "Dieser Mac ist bei einer Geräteverwaltung (MDM) angemeldet\(viaDEP ? " (automatische Geräteregistrierung)" : ""). Sie kann Einstellungen und Apps vorgeben."
                : "Dieser Mac ist bei keiner Geräteverwaltung (MDM) angemeldet.")
        }
    }

    private static func link(_ title: String, _ url: URL?) -> [Offer] {
        url.map { [.link(title: title, url: $0)] } ?? []
    }

    /// Form einer Tagesangabe: Zeitpunkt („vor 3 Tagen“, „gestern“) oder Dauer („seit 3 Tagen“, „seit gestern“).
    enum DayPhrase {
        case ago, since
    }

    /// Tagesangabe für `days` Kalendertage (`CalendarDays`, dasselbe Maß wie die Schwellen der `SecurityPolicy`).
    static func dayText(_ days: Int, _ phrase: DayPhrase) -> String {
        let since = phrase == .since ? "seit " : ""
        return switch days {
        case ...0: since + "heute"
        case 1: since + "gestern"
        default: "\(phrase == .ago ? "vor" : "seit") \(days) Tagen"
        }
    }
}

/// Bereich „Sicherheit“, Kachel und Menüleiste – einmal je Zustandsänderung in `PresentationSnapshot` berechnet.
public struct SecurityOverview: Hashable, Sendable {
    /// Zeilen in Anzeigereihenfolge (`SecurityCheckKind.allCases`).
    public let checks: [SecurityCheckPresentation]
    /// Schlechteste Ampel (good < unknown < warning < critical); `nil` ohne Prüfungen.
    public let worstState: SecurityState?
    /// Prüfungen mit Hinweis oder kritisch.
    public let hintCount: Int
    public let criticalCount: Int
    private let criticalTitles: [String]

    public static func make(checks: [SecurityCheck], now: Date, calendar: Calendar = .current) -> SecurityOverview {
        let ordered = checks.sorted { displayOrder($0.kind) < displayOrder($1.kind) }
        let critical = ordered.filter { $0.state == .critical }
        return SecurityOverview(
            checks: ordered.map { SecurityCheckPresentation($0, now: now, calendar: calendar) },
            worstState: ordered.map(\.state).max { $0.displayRank < $1.displayRank },
            hintCount: ordered.filter { $0.state == .warning || $0.state == .critical }.count,
            criticalCount: critical.count,
            criticalTitles: critical.map(\.kind.displayName)
        )
    }

    private static func displayOrder(_ kind: SecurityCheckKind) -> Int {
        SecurityCheckKind.allCases.firstIndex(of: kind) ?? .max
    }

    /// Farbe der Kachel; `nil` ohne Prüfungen (Standardfarbe).
    public var tileTone: PresentationTone? { worstState?.tone }

    /// Unterzeile der Kachel; nennt die schlechteste Ampel auch in Worten (nicht nur über die Farbe). Ohne Prüfungen
    /// (vor dem ersten v2-Scan) steht „Noch nicht geprüft“ statt einer Entwarnung.
    public var tileCaption: String {
        switch worstState {
        case .critical?: "Mindestens eine Prüfung kritisch"
        case .warning?: "Hinweise zu Schutzfunktionen"
        case .unknown?: "Nicht alle Prüfungen möglich"
        case .good?: "Alles in Ordnung"
        case nil: "Noch nicht geprüft"
        }
    }

    /// Statuszeile im Menüleisten-Popover, nur wenn mindestens eine Prüfung kritisch ist.
    public var menuBarStatusLine: String? {
        switch criticalTitles.count {
        case 0: nil
        case 1: "Sicherheit: \(criticalTitles[0]) kritisch"
        default: "Sicherheit: \(criticalTitles.count) Prüfungen kritisch"
        }
    }

    public static func canRunHelperActions(_ state: HelperState?) -> Bool { state == .ready }

    /// Ob eine Aktion angeboten werden kann: „Jetzt suchen“ immer, Helper-Aktionen nur bei bereitem Helper.
    public static func isAvailable(_ action: SecurityAction, helperState: HelperState?) -> Bool {
        !action.requiresHelper || canRunHelperActions(helperState)
    }

    /// Hinweis, warum Helper-Aktionen gesperrt sind; `nil` bei bereitem oder (noch) unbekanntem Helper.
    public static func helperNote(for state: HelperState?) -> String? {
        switch state {
        case .ready?, nil: nil
        case .outdated?: "Der Helper ist veraltet. Bitte in den Einstellungen „\(HelperStatePresentation.Action.reinstall.title)“ wählen, um Schutzfunktionen einzuschalten."
        // Ohne Aktion in den Einstellungen (`HelperStatePresentation.action == nil`) nur der Grund.
        case let state? where HelperStatePresentation(state).action == nil:
            "Schutzfunktionen können nicht eingeschaltet werden – Helper: \(HelperStatePresentation(state).text)."
        case .some: "Zum Einschalten von Schutzfunktionen wird der Helper benötigt (Einstellungen)."
        }
    }
}

extension SecurityState {
    /// Semantische Farbe der Ampel; `unknown` grau (neutral).
    public var tone: PresentationTone {
        switch self {
        case .good: .positive
        case .warning: .warning
        case .critical: .critical
        case .unknown: .neutral
        }
    }

    /// Statustext einer Zeile: `displayName` mit großem Anfangsbuchstaben („In Ordnung“, „Kritisch“ …).
    public var statusTitle: String { displayName.prefix(1).uppercased() + displayName.dropFirst() }
}
