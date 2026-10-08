import Foundation

/// Ein wiederherstellbarer Beleg im Verlauf: entfernter Autostart-Eintrag oder Änderung an einer Agenten-Konfiguration.
public enum RestorableChange: Hashable, Sendable, Identifiable {
    case autostart(ReceiptEntry)
    case agentConfig(AgentConfigChange)

    public var id: UUID {
        switch self {
        case .autostart(let entry): entry.id
        case .agentConfig(let change): change.id
        }
    }

    /// Anzeigename: Label des Autostart-Eintrags bzw. „„files“ (Claude Code)“.
    public var label: String {
        switch self {
        case .autostart(let entry): entry.label
        case .agentConfig(let change): change.label
        }
    }

    public var changedAt: Date {
        switch self {
        case .autostart(let entry): entry.removedAt
        case .agentConfig(let change): change.changedAt
        }
    }

    /// Art des Verlaufsereignisses, zu dem der Beleg gehört.
    var eventKind: ChangeEvent.Kind {
        switch self {
        case .autostart: .removed
        case .agentConfig(let change): change.eventKind
        }
    }

    /// „Entfernt“ bzw. „Geändert“ (wie im Verlauf) – für die Liste „Wiederherstellbar“.
    public var actionName: String { eventKind.displayName }

    /// Hilfetext des Knopfs „Wiederherstellen …“.
    public var restoreHelp: String {
        switch self {
        case .autostart: "Gesicherte Plist zurücklegen"
        case .agentConfig: "Gesicherte Konfiguration bzw. den Eintrag zurücklegen"
        }
    }
}

extension AgentConfigChange {
    /// Art des Verlaufsereignisses, das diese Änderung erzeugt: entfernt bzw. geändert.
    var eventKind: ChangeEvent.Kind { kind == .removedServer ? .removed : .modified }
}

extension HistoryFilter {
    /// Ob eine Änderung an einer Agenten-Konfiguration passt (Art „Agenten“, Änderungsart, Zeitraum ab `changedAt`).
    public func matches(_ change: AgentConfigChange, now: Date) -> Bool {
        (category == .all || category == .agents)
            && (kind == nil || kind == change.eventKind)
            && period.start(relativeTo: now).map { change.changedAt >= $0 } ?? true
    }

    public func matches(_ restorable: RestorableChange, now: Date) -> Bool {
        switch restorable {
        case .autostart(let entry): matches(entry, now: now)
        case .agentConfig(let change): matches(change, now: now)
        }
    }
}

extension RestoreMatching {
    /// Wiederherstellbares je Ereignis: Autostart-Belege wie bisher (`receiptsByEvent`), Agenten-Änderungen beim
    /// Ereignis desselben MCP-Servers (`entryID`) mit passender Art, erkannt höchstens `tolerance` von `changedAt`
    /// entfernt – das zeitlich nächste; jedes Ereignis erhält höchstens einen Beleg, neuere Änderungen wählen zuerst.
    public static func restorablesByEvent(
        events: [HistoryEvent], receipts: [ReceiptEntry], changes: [AgentConfigChange], tolerance: TimeInterval = defaultTolerance
    ) -> [HistoryEvent.ID: RestorableChange] {
        var result = receiptsByEvent(events: events, receipts: receipts, tolerance: tolerance).mapValues(RestorableChange.autostart)
        for change in changes.sorted(by: { $0.changedAt > $1.changedAt }) {
            let best = closestUnmatched(to: change.changedAt, in: events, matched: result, tolerance: tolerance) { event in
                event.event.kind == change.eventKind && event.event.subject.recordID == change.server.entryID
            }
            if let best { result[best.id] = .agentConfig(change) }
        }
        return result
    }

    /// Belege ohne geladenes Ereignis, die zu `filter` passen, neueste zuerst – die Liste „Wiederherstellbar“.
    public static func unmatchedRestorables(
        receipts: [ReceiptEntry], changes: [AgentConfigChange], matches: [HistoryEvent.ID: RestorableChange],
        filter: HistoryFilter, now: Date
    ) -> [RestorableChange] {
        let matched = Set(matches.values.map(\.id))
        return (receipts.map(RestorableChange.autostart) + changes.map(RestorableChange.agentConfig))
            .filter { !matched.contains($0.id) && filter.matches($0, now: now) }
            .sorted { $0.changedAt > $1.changedAt }
    }
}
