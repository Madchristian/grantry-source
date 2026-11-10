import Foundation
import GrantryShared

/// Quelle einer Änderung im Wachbuch (Spec 2026-11-08 §5.1); der Rohwert ist der maschinenlesbare Typ der Marke
/// (`WatchbookEvent.type`) und ändert sich daher nicht. Die Ereignisleiste wählt danach das Symbol.
public enum WatchbookChangeSource: String, CaseIterable, Hashable, Sendable {
    case autostart = "change.autostart"
    case networkService = "change.network"
    case app = "change.app"
    /// MCP-Server und automatische Freigaben der KI-Agenten.
    case agent = "change.agent"
    /// Kernel- und Systemerweiterungen, Plug-ins in Systemdiensten (TM-13.3).
    case extensionRecord = "change.extension"

    /// Quelle einer Marke; `nil` für Befunde, Systemereignisse und unbekannte Typen.
    public init?(event: WatchbookEvent) {
        guard event.kind == .change else { return nil }
        self.init(rawValue: event.type)
    }
}

/// Änderungen aus dem Verlauf (`HistoryEvent`) als Marken im Wachbuch (TM-12.4): Zeitpunkt der Erkennung, Quelle,
/// Kurztext und Verweis auf den Verlaufseintrag – die Marke trägt dessen ID. Dazu der Befund „neuer aus dem Netz
/// erreichbarer Dienst“ (`FindingRules.exposedServiceFindings`).
///
/// Marken bekommen Autostart, Netzwerkdienste (ohne vermutliche Clients, `NetworkListener.isBenignClientUDP`), Apps,
/// Agenten und Erweiterungen (ohne Verursacher: eine Erweiterung ist kein Programm). Berechtigungen, Sicherheitsprüfungen und eigene Aktionen des Task-Managers bleiben im Verlauf.
///
/// Kurztexte nach Spec §4.5: der Titel aus `ChangeDescription` und ein Name – keine Befehlszeilen, keine Pfade;
/// Programme anderer Benutzer heißen „Andere Konten“ (`WatchbookSubject`).
public enum WatchbookChangeMarks {
    /// Längengrenze für fremde Namen im Kurztext.
    static let maximumNameLength = 80
    static let otherAccountsName = "Andere Konten"

    /// Marken und Befunde zu `history`, aufsteigend nach Zeitpunkt.
    public static func events(for history: [HistoryEvent], currentUID: UInt32) -> [WatchbookEvent] {
        let marks = history.compactMap { mark(for: $0, currentUID: currentUID) }
        let findings = FindingRules.exposedServiceFindings(in: history.map(\.event), currentUID: currentUID)
        return (marks + findings.map(\.watchbookEvent)).sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Marke eines Verlaufseintrags; `nil`, wenn seine Quelle nicht ins Wachbuch gehört.
    public static func mark(for entry: HistoryEvent, currentUID: UInt32) -> WatchbookEvent? {
        let event = entry.event
        let detail: (source: WatchbookChangeSource, name: String, subject: WatchbookSubject?)
        switch event.subject {
        case .autostartItem(let item):
            detail = (.autostart, limited(item.label), nil)
        case .networkListener(let listener):
            guard !listener.isBenignClientUDP else { return nil }
            let subject = WatchbookSubject(processNamed: listener.processName, uid: listener.uid,
                                           currentUID: currentUID)
            detail = (.networkService, "\(subject?.name ?? otherAccountsName), \(listener.portLabel)", subject)
        case .installedApp(let app):
            detail = (.app, limited(app.nameWithVersion), .program(limited(app.name)))
        case .mcpServer(let server):
            detail = (.agent, "„\(limited(server.name))“ in \(limited(server.locationDescription))", nil)
        case .agentAutoApproval(let approval):
            detail = (.agent, "\(limited(approval.locationDescription)), \(limited(approval.setting))", nil)
        case .extensionRecord(let record):
            detail = (.extensionRecord, "\(limited(record.name ?? record.bundleID)) (\(record.kind.displayName))", nil)
        case .grant, .securityCheck, .taskAction:
            return nil
        }
        return WatchbookEvent(id: entry.id, kind: .change, type: detail.source.rawValue, start: event.detectedAt,
                              end: event.detectedAt, tone: nil, subject: detail.subject,
                              summary: "\(ChangeDescription(event).title): \(detail.name)")
    }

    /// Verlauf für den Nachtrag beim Einschalten: alle Einträge innerhalb der Aufbewahrung des Wachbuchs.
    public static func history(from store: any SnapshotStore, now: Date) async throws -> [HistoryEvent] {
        try await store.events(since: retentionStart(now: now))
    }

    static func retentionStart(now: Date) -> Date { now.addingTimeInterval(-WatchbookStore.retention) }

    private static func limited(_ text: String) -> String {
        String(DisplayText.singleLine(text).prefix(maximumNameLength))
    }
}

extension WatchbookEvent {
    /// Fenster um einen Zeitpunkt für das Panel „Zu diesem Zeitpunkt“ (Spec §5.1): ±5 min.
    public static let neighborhood: TimeInterval = 300

    /// `time` ± `window`, beide Grenzen eingeschlossen.
    static func range(around time: Date, within window: TimeInterval) -> Range<Date> {
        range(from: time.addingTimeInterval(-window), through: time.addingTimeInterval(window))
    }

    /// `start` bis einschließlich `end`.
    static func range(from start: Date, through end: Date) -> Range<Date> {
        start..<Date(timeIntervalSinceReferenceDate: end.timeIntervalSinceReferenceDate.nextUp)
    }
}

extension WatchbookStore {
    /// Ereignisse, die `time` ± `window` berühren – auch laufende Befunde, die früher begannen –, aufsteigend nach
    /// Beginn; `pendingEvents` sind noch nicht geschriebene Einträge des Journals.
    public func events(around time: Date, within window: TimeInterval = WatchbookEvent.neighborhood,
                       pendingEvents: [WatchbookEvent] = []) -> [WatchbookEvent] {
        events(in: WatchbookEvent.range(around: time, within: window), pendingEvents: pendingEvents)
    }

    func events(in range: Range<Date>, pendingEvents: [WatchbookEvent]) -> [WatchbookEvent] {
        var merger = WatchbookEventMerger()
        merger.add(events(in: range))
        merger.add(pendingEvents)
        return merger.overlapping(range)
    }
}

extension WatchbookJournal {
    /// Ereignisse um `time` einschließlich der noch nicht geschriebenen (`WatchbookStore.events(around:)`).
    public func events(around time: Date, within window: TimeInterval = WatchbookEvent.neighborhood)
        -> [WatchbookEvent] {
        store.events(around: time, within: window, pendingEvents: pendingEvents)
    }

    /// Übernimmt Änderungen aus dem Verlauf als Marken und Befunde (`WatchbookChangeMarks.events`): beim Einschalten
    /// den Nachtrag (`WatchbookChangeMarks.history(from:now:)`, nur Marken, keine Messwerte), nach jedem Scan die neuen
    /// Einträge. Was schon im Wachbuch steht oder gepuffert ist (gleiche ID), wird nicht erneut geschrieben – ein
    /// erneuter Scan oder Nachtrag ergibt keine doppelten Marken. Einträge vor der Aufbewahrung entfallen.
    /// - Returns: die neu aufgenommenen Ereignisse.
    @discardableResult
    public func recordChanges(_ history: [HistoryEvent], currentUID: UInt32, now: Date) throws -> [WatchbookEvent] {
        let oldest = WatchbookChangeMarks.retentionStart(now: now)
        let candidates = WatchbookChangeMarks.events(for: history.filter { $0.event.detectedAt >= oldest },
                                                     currentUID: currentUID)
        guard let first = candidates.first?.start, let last = candidates.last?.start else { return [] }
        var known = Set(store.events(in: WatchbookEvent.range(from: first, through: last), pendingEvents: pendingEvents)
            .map(\.id))
        let missing = candidates.filter { known.insert($0.id).inserted }
        for event in missing { try record(event, now: now) }
        return missing
    }
}
