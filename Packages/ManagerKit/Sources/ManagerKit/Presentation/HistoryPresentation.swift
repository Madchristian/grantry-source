import Foundation

/// Filter des Verlaufs (Spec §6): Art des Eintrags, Änderungsart und Zeitraum.
public struct HistoryFilter: Hashable, Sendable {
    /// Art des betroffenen Eintrags.
    public enum Category: Hashable, Sendable, CaseIterable {
        case all, apps, agents, permissions, autostart, security, network

        public var displayName: String {
            switch self {
            case .all: "Alle Arten"
            case .apps: "Apps"
            case .agents: "Agenten"
            case .permissions: "Berechtigungen"
            case .autostart: "Autostart"
            case .security: "Sicherheit"
            case .network: "Netzwerk"
            }
        }
    }

    /// Zeitraum, rückwärts ab jetzt.
    public enum Period: Hashable, Sendable, CaseIterable {
        case day, week, month, all

        public var displayName: String {
            switch self {
            case .day: "Letzte 24 Stunden"
            case .week: "Letzte 7 Tage"
            case .month: "Letzte 30 Tage"
            case .all: "Gesamter Verlauf"
            }
        }

        /// Frühester eingeschlossener Zeitpunkt; `nil` für den gesamten Verlauf.
        public func start(relativeTo now: Date) -> Date? {
            let days: Double? = switch self {
            case .day: 1
            case .week: 7
            case .month: 30
            case .all: nil
            }
            return days.map { now.addingTimeInterval(-$0 * 24 * 60 * 60) }
        }
    }

    public var category: Category
    /// `nil`: alle Änderungsarten.
    public var kind: ChangeEvent.Kind?
    public var period: Period

    public init(category: Category = .all, kind: ChangeEvent.Kind? = nil, period: Period = .all) {
        self.category = category
        self.kind = kind
        self.period = period
    }

    /// Ob ein Filter von der Vorgabe abweicht.
    public var isActive: Bool { self != HistoryFilter() }

    public func matches(_ event: HistoryEvent, now: Date) -> Bool {
        matchesCategory(event.event.subject)
            && (kind == nil || event.event.kind == kind)
            && period.start(relativeTo: now).map { event.event.detectedAt >= $0 } ?? true
    }

    /// Ob ein Wiederherstellungsbeleg passt: Er steht für einen entfernten Autostart-Eintrag, entfernt zu
    /// `removedAt`.
    public func matches(_ receipt: ReceiptEntry, now: Date) -> Bool {
        (category == .all || category == .autostart)
            && (kind == nil || kind == .removed)
            && period.start(relativeTo: now).map { receipt.removedAt >= $0 } ?? true
    }

    /// Die passenden Events in unveränderter Reihenfolge.
    public func apply(_ events: [HistoryEvent], now: Date) -> [HistoryEvent] {
        events.filter { matches($0, now: now) }
    }

    /// Ob ältere Events als `oldest` (das älteste geladene) noch in den Zeitraum fallen können – sonst lohnt es
    /// nicht, weitere Seiten zu laden. Ohne geladene Events: ja.
    public func canMatchEvents(olderThan oldest: HistoryEvent?, now: Date) -> Bool {
        guard let oldest, let start = period.start(relativeTo: now) else { return true }
        return oldest.event.detectedAt > start
    }

    private func matchesCategory(_ subject: ChangeSubject) -> Bool {
        switch (category, subject) {
        case (.all, _), (.apps, .installedApp), (.permissions, .grant), (.autostart, .autostartItem),
             (.security, .securityCheck), (.network, .networkListener): true
        case (.agents, .mcpServer), (.agents, .agentAutoApproval): true
        case (.agents, _): false
        case (.apps, _), (.permissions, _), (.autostart, _), (.security, _), (.network, _): false
        }
    }
}

extension ChangeEvent.Kind {
    /// Deutscher Name der Änderungsart (Filter im Verlauf).
    public var displayName: String {
        switch self {
        case .added: "Neu"
        case .modified: "Geändert"
        case .removed: "Entfernt"
        }
    }
}

/// Ordnet Wiederherstellungsbelege den „Entfernt“-Ereignissen im Verlauf zu.
///
/// Belege mit `eventID` gehören zu genau diesem Ereignis. Belege ohne (`ActionCoordinator.remove` kennt das Ereignis
/// noch nicht, es entsteht erst beim folgenden Scan) gehören zu einem Entfernt-Ereignis eines launchd-Eintrags mit
/// gleichem Label, gleichem Plist-Speicherort (Verzeichnis- und Dateiname der Plist wie im Backup, Benutzer- bzw.
/// System-Speicher passend zur Domain) und einem Erkennungszeitpunkt höchstens `tolerance` von `removedAt` entfernt.
/// Passen mehrere, gewinnt das zeitlich nächste; jedes Ereignis erhält höchstens einen Beleg, neuere Belege wählen
/// zuerst.
public enum RestoreMatching {
    /// Spielraum zwischen `removedAt` und der Erkennung im nächsten Scan (Prüfscan, verzögerte Scans, Uhrdrift).
    public static let defaultTolerance: TimeInterval = 10 * 60

    /// Beleg je Ereignis-ID.
    public static func receiptsByEvent(
        events: [HistoryEvent], receipts: [ReceiptEntry], tolerance: TimeInterval = defaultTolerance
    ) -> [HistoryEvent.ID: ReceiptEntry] {
        let removals = events.filter { $0.event.kind == .removed && $0.removedLaunchdItem != nil }
        var matches: [HistoryEvent.ID: ReceiptEntry] = [:]
        // Belege mit bekannter Ereignis-ID zuerst, damit die Heuristik ihnen kein Ereignis wegnimmt.
        for entry in receipts {
            if let eventID = entry.eventID, removals.contains(where: { $0.id == eventID }) {
                matches[eventID] = entry
            }
        }
        for entry in receipts.sorted(by: { $0.removedAt > $1.removedAt }) where entry.eventID == nil {
            let best = closestUnmatched(to: entry.removedAt, in: removals, matched: matches, tolerance: tolerance) { event in
                Self.matches(entry, event, tolerance: tolerance)
            }
            if let best { matches[best.id] = entry }
        }
        return matches
    }

    /// Das zeitlich nächste Ereignis zu `date` unter `events`, das noch keinen Beleg hat (`matched`), höchstens
    /// `tolerance` entfernt liegt und `isCandidate` erfüllt – gemeinsame Zuordnung für Autostart- und Agenten-Belege.
    static func closestUnmatched<Value>(
        to date: Date, in events: [HistoryEvent], matched: [HistoryEvent.ID: Value], tolerance: TimeInterval,
        where isCandidate: (HistoryEvent) -> Bool
    ) -> HistoryEvent? {
        func distance(_ event: HistoryEvent) -> TimeInterval { abs(event.event.detectedAt.timeIntervalSince(date)) }
        return events
            .filter { matched[$0.id] == nil && distance($0) <= tolerance && isCandidate($0) }
            .min { distance($0) < distance($1) }
    }

    static func matches(_ entry: ReceiptEntry, _ event: HistoryEvent, tolerance: TimeInterval) -> Bool {
        guard let item = event.removedLaunchdItem, item.label == entry.receipt.label,
              (item.domain == .system) == entry.receipt.isPrivileged,
              let plistPath = item.plistPath,
              storageLocation(of: plistPath) == storageLocation(of: entry.receipt.backupPath)
        else { return false }
        return distance(entry, event) <= tolerance
    }

    private static func distance(_ entry: ReceiptEntry, _ event: HistoryEvent) -> TimeInterval {
        abs(event.event.detectedAt.timeIntervalSince(entry.removedAt))
    }

    /// Verzeichnis- und Dateiname (`LaunchAgents/x.plist`): Backups liegen als `<Zeitstempel>/<Verzeichnis>/<Datei>`,
    /// so lässt sich der ursprüngliche Ort ohne absoluten Pfad (Home-Verzeichnis, Symlinks) vergleichen.
    private static func storageLocation(of path: String) -> [String] {
        Array(URL(fileURLWithPath: path).pathComponents.suffix(2))
    }
}

extension HistoryEvent {
    /// Der entfernte launchd-Eintrag, sofern das Ereignis ein solches Entfernen ist.
    fileprivate var removedLaunchdItem: AutostartItem? {
        guard event.kind == .removed, case .autostartItem(let item) = event.subject, item.source == .launchd else { return nil }
        return item
    }
}

extension ActionOutcomePresentation {
    /// Ergebnis von `ActionCoordinator.restore(receiptID:)`.
    public static func restore(_ entry: ReceiptEntry, outcome: ActionOutcome) -> ActionOutcomePresentation {
        ActionOutcomePresentation(outcome, successMessage: "„\(entry.label)“ wurde wiederhergestellt.")
    }
}
