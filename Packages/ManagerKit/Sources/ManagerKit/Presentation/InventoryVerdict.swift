import Foundation

/// Urteil der Zustandszeile in den Liste-Detail-Bereichen Berechtigungen, Autostart, Agenten und Apps (Spec 2026-11-10
/// § 11 Entscheidung 6, § 11.2 a): „N Apps auffällig“ bzw. „N Einträge auffällig“, sonst „Ruhig“; höchstens drei Chips
/// (kritisch bzw. prüfen, neu seit 7 Tagen, ein bereichseigener wie deaktiviert bzw. akzeptiert). Nur aus den vorhandenen
/// Badges der Einträge; „auffällig“ heißt wie bei der Kachel „Auffällig“ ein Befund mittel oder hoch (`FindingFilter.flagged`).
/// Fehlen Quellen, gibt es keine Entwarnung.
public struct InventoryVerdict: Hashable, Sendable {
    /// Wie die Einträge des Bereichs heißen.
    public enum Subject: Hashable, Sendable {
        case apps, entries
    }

    static let maximumItems = 3

    public let title: String
    /// Schildform: ruhig, Befund oder ohne Urteil („offen“, Spec § 11.3 c).
    public let shield: VerdictShield
    public let items: [SystemVerdict.Item]

    /// Schild mit Befund-Punkt.
    public var isFinding: Bool { shield == .finding }

    /// Vor dem ersten Scan: kein Urteil, deshalb die offene Schildform statt einer Entwarnung.
    public static let notScanned = InventoryVerdict(title: String(localized: "Noch nicht geprüft"), shield: .open,
                                                    items: [])

    private init(title: String, shield: VerdictShield, items: [SystemVerdict.Item]) {
        self.title = title
        self.shield = shield
        self.items = items
    }

    /// - Parameters:
    ///   - entryBadges: Badges je Eintrag der Liste (bei Gruppen zusammengefasst, je Art einmal).
    ///   - extra: dritter, bereichseigener Chip; nur, wenn Platz bleibt.
    ///   - missingSources: Quellen, die der letzte Scan nicht lesen konnte (`AreaCoverage.gaps`).
    public init(entryBadges: [[RecordBadge]], subject: Subject, extra: SystemVerdict.Item? = nil,
                missingSources: Int = 0) {
        let severities = entryBadges.map { badges in
            badges.compactMap { badge -> RiskFinding.Severity? in
                if case .review(let severity) = badge { severity } else { nil }
            }.max()
        }
        let critical = severities.count { $0 == .high }
        let review = severities.count { $0 == .medium }
        let new = entryBadges.count { $0.contains(.new) }
        let flagged = critical + review
        if flagged > 0 {
            title = Self.flaggedTitle(flagged, subject: subject)
        } else if missingSources > 0 {
            title = String(localized: "Nicht vollständig geprüft")
        } else {
            title = String(localized: "Ruhig")
        }
        shield = flagged > 0 || missingSources > 0 ? .finding : .calm
        let candidates: [SystemVerdict.Item?] = [
            missingSources > 0 ? SystemVerdict.Item(text: Self.missingText(missingSources), tone: .warning) : nil,
            critical > 0 ? SystemVerdict.Item(text: String(localized: "\(critical) kritisch"), tone: .critical) : nil,
            review > 0 ? SystemVerdict.Item(text: String(localized: "\(review) prüfen"), tone: .warning) : nil,
            new > 0 ? SystemVerdict.Item(text: String(localized: "\(new) neu seit 7 Tagen"), tone: .neutral) : nil,
            extra,
        ]
        items = Array(candidates.compactMap(\.self).prefix(Self.maximumItems))
    }

    private static func flaggedTitle(_ count: Int, subject: Subject) -> String {
        switch (subject, count) {
        case (.apps, 1): String(localized: "1 App auffällig")
        case (.apps, _): String(localized: "\(count) Apps auffällig")
        case (.entries, 1): String(localized: "1 Eintrag auffällig")
        case (.entries, _): String(localized: "\(count) Einträge auffällig")
        }
    }

    private static func missingText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 Quelle fehlt") : String(localized: "\(count) Quellen fehlen")
    }
}

extension InventoryVerdict {
    /// Zustandszeile im Bereich Autostart (LB-2.3, #540): über alle Einträge, unabhängig von Suche und Filter; dritter
    /// Chip „N deaktiviert“.
    public static func autostart(_ items: [AutostartItem], badges: RecordBadges, missingSources: Int) -> InventoryVerdict {
        let disabled = items.count { !$0.isEnabled }
        return InventoryVerdict(
            entryBadges: items.map { badges.badges(for: $0.id) }, subject: .entries,
            extra: disabled > 0 ? SystemVerdict.Item(text: String(localized: "\(disabled) deaktiviert"), tone: .neutral)
                : nil,
            missingSources: missingSources
        )
    }
}
