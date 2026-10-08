import Foundation

/// Kennzeichnung eines Eintrags in Listen.
public enum RecordBadge: Hashable, Sendable {
    /// In den letzten `RecordBadges.newItemInterval` hinzugekommen.
    case new
    /// Mindestens ein `RiskFinding`; trägt den höchsten Schweregrad.
    case review(RiskFinding.Severity)
    /// Ein `CleanupHint` liegt vor.
    case cleanup

    /// Deutsche Kurzbeschriftung.
    public var title: String {
        switch self {
        case .new: "neu"
        case .review: "prüfen"
        case .cleanup: "aufräumen"
        }
    }

    public var tone: PresentationTone {
        switch self {
        case .new, .cleanup: .neutral
        case .review(.high): .critical
        case .review(.medium), .review(.low): .warning
        }
    }

    /// SF Symbol, das bei „prüfen“ den Schweregrad unabhängig von der Farbe zeigt; `nil` für die übrigen Badges.
    public var systemImage: String? {
        switch self {
        case .new, .cleanup: nil
        case .review(.high): "exclamationmark.octagon.fill"
        case .review(.medium): "exclamationmark.triangle.fill"
        case .review(.low): "info.circle.fill"
        }
    }

    /// Text für VoiceOver; bei „prüfen“ mit Schweregrad.
    public var accessibilityLabel: String {
        switch self {
        case .new, .cleanup: title
        case .review(let severity): "\(title), Schweregrad \(severity.displayName)"
        }
    }
}

extension RiskFinding.Severity {
    /// Deutscher Name des Schweregrads.
    public var displayName: String {
        switch self {
        case .low: "niedrig"
        case .medium: "mittel"
        case .high: "hoch"
        }
    }
}

/// Ermittelt die Badges von Einträgen. Die Eingaben werden einmal indiziert, damit `badges(for:)` je Listenzeile
/// günstig bleibt.
public struct RecordBadges: Hashable, Sendable {
    /// Zeitraum, in dem ein hinzugekommener Eintrag als „neu“ gilt (7 Tage).
    public static let newItemInterval: TimeInterval = 7 * 24 * 60 * 60

    private let newRecordIDs: Set<String>
    private let severities: SeverityIndex
    private let cleanupRecordIDs: Set<String>

    /// - Parameter events: gespeicherte Events; `.added` ab `now - newItemInterval` macht einen Eintrag „neu“.
    public init(findings: [RiskFinding], events: [HistoryEvent], cleanupHints: [CleanupHint], now: Date) {
        newRecordIDs = Set(events.recentAdditions(now: now).map(\.event.subject.recordID))
        severities = SeverityIndex(findings)
        cleanupRecordIDs = Set(cleanupHints.map(\.recordID))
    }

    /// Badges in fester Reihenfolge: `.new`, `.review`, `.cleanup`.
    public func badges(for recordID: String) -> [RecordBadge] {
        var badges: [RecordBadge] = []
        if newRecordIDs.contains(recordID) { badges.append(.new) }
        if let severity = severities.severity(of: recordID) { badges.append(.review(severity)) }
        if cleanupRecordIDs.contains(recordID) { badges.append(.cleanup) }
        return badges
    }

    /// Badges eines einzelnen Eintrags; für viele Einträge einmal `RecordBadges(…)` bilden und wiederverwenden.
    public static func badges(
        for recordID: String, findings: [RiskFinding], events: [HistoryEvent], cleanupHints: [CleanupHint], now: Date
    ) -> [RecordBadge] {
        RecordBadges(findings: findings, events: events, cleanupHints: cleanupHints, now: now).badges(for: recordID)
    }
}

extension Sequence<HistoryEvent> {
    /// `.added`-Events ab `now - RecordBadges.newItemInterval`.
    func recentAdditions(now: Date) -> [HistoryEvent] {
        let start = now.addingTimeInterval(-RecordBadges.newItemInterval)
        return filter { $0.event.kind == .added && $0.event.detectedAt >= start }
    }
}

/// Höchster Schweregrad je `recordID`.
struct SeverityIndex: Hashable, Sendable {
    private let byRecordID: [String: RiskFinding.Severity]

    init(_ findings: [RiskFinding]) {
        byRecordID = Dictionary(findings.map { ($0.recordID, $0.severity) }, uniquingKeysWith: max)
    }

    private init(byRecordID: [String: RiskFinding.Severity]) {
        self.byRecordID = byRecordID
    }

    /// Einträge, deren höchster Schweregrad `isIncluded` erfüllt.
    func recordIDs(where isIncluded: (RiskFinding.Severity) -> Bool) -> Set<String> {
        Set(byRecordID.filter { isIncluded($0.value) }.keys)
    }

    func severity(of recordID: String) -> RiskFinding.Severity? { byRecordID[recordID] }

    /// Nur die Einträge zu `recordIDs`.
    func restricted(to recordIDs: some Sequence<String>) -> SeverityIndex {
        let recordIDs = Set(recordIDs)
        return SeverityIndex(byRecordID: byRecordID.filter { recordIDs.contains($0.key) })
    }

    /// Höchster Schweregrad aller enthaltenen Einträge.
    var highest: RiskFinding.Severity? { byRecordID.values.max() }
}
