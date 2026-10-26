import Foundation

/// Schwelle des Befund-Filters der Listen (Berechtigungen, Autostart, Apps, Agenten; #275) – dieselbe wie bei der
/// Kachel „Auffällig“ (`FlaggedBreakdown`), damit die Liste genau die gezählten Einträge zeigt.
public enum FindingFilter: Hashable, Sendable, CaseIterable {
    /// Alle Einträge, mit und ohne Befund.
    case all
    /// Nur auffällige Einträge: höchster Befund mittel oder hoch (`DashboardMetrics.flaggedCount`).
    case flagged
    /// Alle Einträge mit Befund, auch reine Hinweise (niedrig); setzt die Kachel „Auffällig“, wenn es nur Hinweise gibt.
    case withFindings

    /// Niedrigster Schweregrad, den der höchste Befund eines Eintrags erreichen muss; `nil`: kein Filter.
    public var minimumSeverity: RiskFinding.Severity? {
        switch self {
        case .all: nil
        case .flagged: .medium
        case .withFindings: .low
        }
    }

    public var isActive: Bool { self != .all }

    /// Ob ein Eintrag mit diesem höchsten Schweregrad (`nil`: ohne Befund) durch den Filter kommt.
    public func includes(_ severity: RiskFinding.Severity?) -> Bool {
        guard let minimumSeverity else { return true }
        return severity.map { $0 >= minimumSeverity } ?? false
    }
}

/// Bereich mit Befunden: Ziel der Kachel „Auffällig“ (`FlaggedBreakdown.tileArea`) und der Sprünge im Hinweis über den
/// Listen (`FlaggedNotice`). Reihenfolge der Fälle = Vorrang beim Öffnen.
public enum FlaggedArea: Hashable, Sendable, CaseIterable {
    case permissions, autostart, apps, agents, network

    /// Inventarbereich gleichen Namens (Sidebar, Abdeckung).
    public var inventoryArea: InventoryArea {
        switch self {
        case .permissions: .permissions
        case .autostart: .autostart
        case .apps: .apps
        case .agents: .agents
        case .network: .network
        }
    }

    /// Deutscher Name wie in der Sidebar.
    public var title: String { inventoryArea.title }
}

/// Auffällige Einträge und Hinweise je Bereich (#275) – eine Quelle für die Kachel „Auffällig“ (`DashboardMetrics`),
/// den Bereich, den sie öffnet (`tileArea`), und den Hinweis auf weitere Bereiche über den Listen (`notice(in:filter:)`).
/// Je Bereich zählen nur Einträge, die seine Liste zeigt: Befunde ohne sichtbare Zeile (etwa zu einer App im Papierkorb,
/// `TrashedApps`) wären über die Kachel nicht erreichbar. Jeder Eintrag zählt einmal, mit seinem höchsten Befund.
public struct FlaggedBreakdown: Hashable, Sendable {
    /// Einträge eines Bereichs nach höchstem Befund.
    public struct Counts: Hashable, Sendable {
        /// Höchster Befund mittel oder hoch.
        public let flagged: Int
        /// Höchster Befund niedrig.
        public let hints: Int

        public init(flagged: Int, hints: Int) {
            self.flagged = flagged
            self.hints = hints
        }

        /// Einträge mit Befund, die `filter` durchlässt; Einträge ohne Befund zählen nie.
        func count(for filter: FindingFilter) -> Int {
            switch filter {
            case .flagged: flagged
            case .all, .withFindings: flagged + hints
            }
        }
    }

    private let countsByArea: [FlaggedArea: Counts]

    public static let empty = FlaggedBreakdown([:])

    /// Bereiche ohne Befunde dürfen fehlen.
    public init(_ countsByArea: [FlaggedArea: Counts]) {
        self.countsByArea = countsByArea.filter { $0.value.flagged + $0.value.hints > 0 }
    }

    /// - Parameter recordIDs: je Bereich die IDs der Einträge, die seine Liste zeigt.
    init(recordIDs: [FlaggedArea: [String]], severities: SeverityIndex) {
        self.init(recordIDs.mapValues { ids in
            let area = severities.restricted(to: ids)
            return Counts(flagged: area.recordIDs { $0 >= .medium }.count, hints: area.recordIDs { $0 == .low }.count)
        })
    }

    /// Einträge mit Befund im Bereich, die `filter` durchlässt.
    public func count(in area: FlaggedArea, for filter: FindingFilter) -> Int {
        countsByArea[area]?.count(for: filter) ?? 0
    }

    /// Summe über alle Bereiche.
    public func total(for filter: FindingFilter) -> Int {
        FlaggedArea.allCases.reduce(0) { $0 + count(in: $1, for: filter) }
    }

    /// Auffällige Einträge (mittel oder hoch) über alle Bereiche.
    public var flaggedCount: Int { total(for: .flagged) }
    /// Einträge, deren höchster Befund niedrig ist, über alle Bereiche.
    public var hintCount: Int { countsByArea.values.reduce(0) { $0 + $1.hints } }

    /// Bereiche mit Einträgen, die `filter` durchlässt, in der Reihenfolge von `FlaggedArea.allCases`.
    public func areas(for filter: FindingFilter) -> [FlaggedArea] {
        FlaggedArea.allCases.filter { count(in: $0, for: filter) > 0 }
    }

    /// Filter, mit dem die Kachel „Auffällig“ öffnet: auffällige Einträge, ohne solche die Hinweise, ohne Befunde keiner.
    public var tileFilter: FindingFilter {
        if flaggedCount > 0 { return .flagged }
        return hintCount > 0 ? .withFindings : .all
    }

    /// Bereich, den die Kachel öffnet: der erste mit Einträgen zu `tileFilter` (Berechtigungen vor Autostart vor Apps vor
    /// Agenten vor Netzwerk) – ein Hinweis bei den Berechtigungen lenkt so nicht von einem auffälligen Autostart-Eintrag
    /// ab. Ohne Befunde die Berechtigungen.
    public var tileArea: FlaggedArea { areas(for: tileFilter).first ?? .permissions }

    /// Hinweis über der Liste von `area`, wenn sie nach `filter` gefiltert ist und andere Bereiche weitere solche
    /// Einträge haben; sonst `nil`.
    public func notice(in area: FlaggedArea, filter: FindingFilter) -> FlaggedNotice? {
        guard filter.isActive else { return nil }
        let others = areas(for: filter).filter { $0 != area }
            .map { FlaggedNotice.Area(area: $0, count: count(in: $0, for: filter)) }
        guard !others.isEmpty else { return nil }
        return FlaggedNotice(shown: count(in: area, for: filter), total: total(for: filter), filter: filter, others: others)
    }
}

/// „3 von 6 auffälligen Einträgen. Weitere: Agenten (2) · Netzwerk (1)“ über einer gefilterten Liste (#275); die
/// Oberfläche macht jeden Bereich in `others` zum Sprung dorthin mit demselben Filter.
public struct FlaggedNotice: Hashable, Sendable {
    /// Ein weiterer Bereich mit Einträgen derselben Schwelle.
    public struct Area: Hashable, Sendable, Identifiable {
        public let area: FlaggedArea
        public let count: Int

        public var id: FlaggedArea { area }
        /// „Agenten (2)“.
        public var label: String { "\(area.title) (\(count))" }
        /// „Agenten: 2 Einträge anzeigen“.
        public var accessibilityLabel: String {
            "\(area.title): \(count == 1 ? "1 Eintrag" : "\(count) Einträge") anzeigen"
        }
    }

    /// Einträge des eigenen Bereichs, die der Filter durchlässt.
    public let shown: Int
    /// Solche Einträge über alle Bereiche.
    public let total: Int
    public let filter: FindingFilter
    /// Weitere Bereiche in der Reihenfolge von `FlaggedArea.allCases`, nie leer.
    public let others: [Area]

    /// „3 von 6 auffälligen Einträgen. Weitere:“ – die Bereiche folgen als Sprünge.
    public var headline: String { "\(share). Weitere:" }

    /// Ausformuliert für VoiceOver: „3 von 6 auffälligen Einträgen stehen hier, weitere in Agenten (2) und Netzwerk (1).“
    public var accessibilityLabel: String {
        "\(share) \(shown == 1 ? "steht" : "stehen") hier, weitere in \(others.map(\.label).enumerationText)."
    }

    /// „3 von 6 auffälligen Einträgen“, „1 von 1 auffälligem Eintrag“, „2 von 5 Einträgen mit Befund“.
    private var share: String {
        let entries = total == 1 ? "Eintrag" : "Einträgen"
        return switch filter {
        case .flagged: "\(shown) von \(total) \(total == 1 ? "auffälligem" : "auffälligen") \(entries)"
        case .all, .withFindings: "\(shown) von \(total) \(entries) mit Befund"
        }
    }
}

extension [String] {
    /// Deutsche Aufzählung: „A, B und C“; ein Element allein, leer ohne Elemente.
    var enumerationText: String {
        guard let last, count > 1 else { return first ?? "" }
        return dropLast().joined(separator: ", ") + " und " + last
    }
}
