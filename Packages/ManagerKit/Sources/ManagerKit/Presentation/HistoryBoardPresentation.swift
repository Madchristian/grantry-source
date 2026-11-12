import Foundation

// Verlauf im Lagebild (LB-3.3, #545; Entwurf LB-3.1, #543, Spec 2026-11-10 § 11.3 d bis g): Urteil der Zustandszeile,
// Tagesgruppen und Zeilentexte aus den vorhandenen Daten – keine neue Regel, nur Darstellung.

/// Urteil der Zustandszeile im Verlauf: ungelesene Änderungen oder „Alles gelesen“, Chips neu und wiederherstellbar,
/// rechts Anzahl und Zeitraum bzw. Treffer des Filters. Ohne Änderungen „Keine Änderungen“, bei fehlenden Quellen und
/// unlesbarer Ablage ohne Entwarnung (Schildform offen, § 11.3 c).
public struct HistoryVerdict: Hashable, Sendable {
    /// Chip der Zustandszeile; den Ton wählt die App (neu im Ton „info“, Fehler kritisch, sonst ruhig).
    public enum Chip: Hashable, Sendable {
        case new(Int)
        case restorable(Int)
        case missingSources(Int)
        case error

        public var text: String {
            switch self {
            case .new(let count): String(localized: "\(count) neu")
            case .restorable(let count): String(localized: "\(count) wiederherstellbar")
            case .missingSources(1): String(localized: "1 Quelle fehlt")
            case .missingSources(let count): String(localized: "\(count) Quellen fehlen")
            case .error: String(localized: "Fehler")
            }
        }
    }

    public let title: String
    public let shield: VerdictShield
    public let chips: [Chip]
    public let facts: String

    /// - Parameters:
    ///   - events: geladene Änderungen (ungefiltert), neueste zuerst.
    ///   - hasMore: ob die Ablage ältere Änderungen hat; dann nennt die Zahl nur die geladenen.
    ///   - unreadCount: ungelesene Änderungen insgesamt (wie das Badge der Seitenleiste).
    ///   - restorableCount: wiederherstellbare Belege, mit und ohne geladenes Ereignis.
    ///   - matchingCount: Treffer des aktiven Filters unter den geladenen Änderungen.
    ///   - missingSources: Quellen, die der letzte Scan nicht lesen konnte.
    public init(events: [HistoryEvent], hasMore: Bool, unreadCount: Int, restorableCount: Int,
                filter: HistoryFilter = HistoryFilter(), matchingCount: Int = 0, missingSources: Int = 0,
                isLoading: Bool = false, loadError: String? = nil) {
        guard !events.isEmpty else {
            if loadError != nil {
                (title, shield, chips, facts) = (String(localized: "Verlauf nicht lesbar"), .open, [.error], "–")
            } else if isLoading {
                (title, shield, chips, facts) = (String(localized: "Verlauf wird geladen"), .open, [], "")
            } else {
                title = String(localized: "Keine Änderungen")
                shield = missingSources > 0 ? .open : .calm
                chips = missingSources > 0 ? [.missingSources(missingSources)] : []
                facts = String(localized: "seit dem ersten Scan")
            }
            return
        }
        title = switch unreadCount {
        case 0: String(localized: "Alles gelesen")
        case 1: String(localized: "1 Änderung ungelesen")
        default: String(localized: "\(unreadCount) Änderungen ungelesen")
        }
        shield = .calm
        if filter.isActive {
            chips = []
            facts = String(localized: "\(matchingCount) von \(events.count) passen")
        } else {
            let newUnread = events.count { !$0.isRead && $0.event.kind == .added }
            chips = [newUnread > 0 ? Chip.new(newUnread) : nil,
                     restorableCount > 0 ? Chip.restorable(restorableCount) : nil].compactMap(\.self)
            let count = switch (hasMore, events.count) {
            case (true, let count): String(localized: "\(count) geladen")
            case (false, 1): String(localized: "1 Änderung")
            case (false, let count): String(localized: "\(count) Änderungen")
            }
            facts = count + " · " + filter.period.displayName
        }
    }
}

/// Tagesgruppe des Verlaufs: „Heute“, „Gestern“, sonst Wochentag und Datum („Montag, 9. Nov.“).
public struct HistoryDay: Identifiable, Hashable, Sendable {
    /// Beginn des Tages.
    public let id: Date
    public let title: String
    public let events: [HistoryEvent]

    /// Gruppiert die Änderungen in ihrer Reihenfolge (neueste zuerst) nach Kalendertag.
    public static func days(of events: [HistoryEvent], now: Date, calendar: Calendar = .current,
                            locale: Locale = Locale(identifier: "de_DE")) -> [HistoryDay] {
        var days: [HistoryDay] = []
        for event in events {
            let start = calendar.startOfDay(for: event.event.detectedAt)
            if let last = days.last, last.id == start {
                days[days.count - 1] = HistoryDay(id: start, title: last.title, events: last.events + [event])
            } else {
                days.append(HistoryDay(id: start, title: title(of: start, now: now, calendar: calendar, locale: locale),
                                       events: [event]))
            }
        }
        return days
    }

    private static func title(of day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return String(localized: "Heute") }
        if calendar.date(byAdding: .day, value: -1, to: today) == day { return String(localized: "Gestern") }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone)
        style = style.weekday(.wide).day().month(.abbreviated)
        return day.formatted(style)
    }
}

/// Titel und Detail einer Änderung im Verlauf (Spec § 11.3 d): der Name des Eintrags, darunter Bereich und Art bzw.
/// was sich geändert hat. Den ganzen Satz der Meldung liefert weiter `ChangeDescription`.
public struct ChangeHeadline: Hashable, Sendable {
    public let name: String
    public let detail: String

    public init(_ event: ChangeEvent) {
        let subject = event.subject
        let description = ChangeDescription(event)
        let specific: String
        switch subject {
        case .grant(let grant):
            name = String(localized: "\(grant.serviceName) für \(grant.client.displayName)")
            let before = event.before.flatMap { if case .grant(let old) = $0 { old } else { nil } }
            if event.kind == .modified, let before {
                specific = "\(before.authValue.displayName) → \(grant.authValue.displayName)"
            } else {
                specific = grant.authValue.displayName
            }
        case .autostartItem(let item):
            name = item.label
            let before = event.before.flatMap { if case .autostartItem(let old) = $0 { old } else { nil } }
            let changes = event.kind == .modified ? before.map { ChangeDescription.changeTexts(from: $0, to: item) } : nil
            specific = changes.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") } ?? item.kind.displayName
        case .mcpServer(let server):
            name = server.name
            let before = event.before.flatMap { if case .mcpServer(let old) = $0 { old } else { nil } }
            specific = event.kind == .modified
                ? ChangeDescription.change(from: before, to: server) : server.locationDescription
        case .installedApp(let app):
            name = app.name
            let before = event.before.flatMap { if case .installedApp(let old) = $0 { old } else { nil } }
            let changes = event.kind == .modified ? before.map { ChangeDescription.appChangeTexts(from: $0, to: app) } : nil
            specific = changes.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") } ?? app.versionText
                ?? description.title
        case .extensionRecord(let record):
            name = record.name ?? record.bundleID
            let before = event.before.flatMap { if case .extensionRecord(let old) = $0 { old } else { nil } }
            let changes = event.kind == .modified
                ? before.map { ChangeDescription.extensionChangeTexts(from: $0, to: record) } : nil
            specific = changes.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") } ?? record.kind.displayName
        case .securityCheck(let check):
            name = check.kind.displayName
            specific = description.title
        case .networkListener(let listener):
            name = listener.processName
            specific = listener.portLabel
        case .agentAutoApproval(let approval):
            name = approval.setting
            specific = approval.locationDescription
        case .taskAction(let record):
            name = record.processName
            specific = description.title
        }
        detail = Self.area(of: subject) + " · " + specific
    }

    /// Bereich der Änderung in der Zeile: „Berechtigung“, „Autostart“, „Agenten“ …
    public static func area(of subject: ChangeSubject) -> String {
        switch subject {
        case .grant: String(localized: "Berechtigung")
        case .autostartItem: String(localized: "Autostart")
        case .securityCheck: String(localized: "Sicherheit")
        case .installedApp: String(localized: "App")
        case .networkListener: String(localized: "Netzwerk")
        case .mcpServer, .agentAutoApproval: String(localized: "Agenten")
        case .extensionRecord: String(localized: "Erweiterung")
        case .taskAction: String(localized: "Task-Manager")
        }
    }
}

extension RemovalReceipt {
    /// „Benutzer“ bzw. „System“ – wo die Sicherung liegt.
    public var storageName: String {
        isPrivileged ? String(localized: "System") : String(localized: "Benutzer")
    }
}

extension RestorableChange {
    /// Titel der Zeile unter „Wiederherstellbar“: Label des Autostart-Eintrags bzw. Name des MCP-Servers.
    public var rowTitle: String {
        switch self {
        case .autostart(let entry): entry.label
        case .agentConfig(let change): change.server.name
        }
    }

    /// Detail der Zeile: was geschah und wo – „Autostart entfernt · Benutzer“ (Ort der Sicherung) bzw. „deaktiviert ·
    /// Claude Code (Projekt web)“ (wohin zurückgelegt wird).
    public var rowDetail: String {
        switch self {
        case .autostart(let entry):
            String(localized: "Autostart entfernt") + " · " + entry.receipt.storageName
        case .agentConfig(let change):
            change.kindText + " · " + change.server.locationDescription
        }
    }
}

extension AgentConfigChange {
    /// „entfernt“, „deaktiviert“ bzw. „aktiviert“.
    var kindText: String {
        switch kind {
        case .removedServer: String(localized: "entfernt")
        case .setEnabled(false): String(localized: "deaktiviert")
        case .setEnabled(true): String(localized: "aktiviert")
        }
    }
}
