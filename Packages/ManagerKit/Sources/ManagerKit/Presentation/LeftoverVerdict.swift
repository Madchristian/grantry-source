import Foundation

/// Urteil der Zustandszeile in Aufräumen › App-Reste (LB-4.2, #548; Spec 2026-11-10 § 11.4): vor dem ersten Ergebnis
/// kein Urteil (Schildform offen, keine Chips, Korrektur 3), danach „Reste von N Apps“, „N Funde offen“ oder „Ruhig“.
/// Eine unvollständige Suche ohne Funde gibt keine Entwarnung. Höchstens drei Chips.
public struct LeftoverVerdict: Hashable, Sendable {
    /// Phase der Suche (wie `CancellableSearch.Phase` in der App).
    public enum Phase: Hashable, Sendable {
        case idle, searching, cancelled, finished
    }

    static let maximumItems = 3

    public let title: String
    public let shield: VerdictShield
    public let items: [SystemVerdict.Item]
    /// Rechts in der Zustandszeile: Funde, Größe und Suchzeit.
    public let facts: String

    /// - Parameters:
    ///   - presentation: Ergebnis der letzten vollständigen Suche; `nil` vor der Suche, während und nach einem Abbruch.
    ///   - extensionLeftovers: Erweiterungen ohne App aus dem Inventar (unabhängig von der Suche).
    public init(phase: Phase, presentation: CleanupPresentation?, extensionLeftovers: Int) {
        guard let presentation else {
            title = switch phase {
            case .searching: String(localized: "Suche läuft")
            case .cancelled: String(localized: "Suche abgebrochen")
            case .idle, .finished: String(localized: "Noch nicht gesucht")
            }
            shield = .open
            items = []
            facts = phase == .idle ? String(localized: "sucht nur auf Knopfdruck")
                : Self.extensionsText(extensionLeftovers) ?? ""
            return
        }
        let rows = presentation.groups.flatMap(\.sections).flatMap(\.rows)
        let findings = rows.count + presentation.autostartItems.count
        let open = findings + presentation.grants.count + extensionLeftovers
        let isIncomplete = LeftoverSearchStand(presentation: presentation, isOutdated: false) == .incomplete
        let apps = presentation.groups.count
        if apps > 0 {
            title = apps == 1 ? String(localized: "Reste von 1 App") : String(localized: "Reste von \(apps) Apps")
        } else if open > 0 {
            title = open == 1 ? String(localized: "1 Fund offen") : String(localized: "\(open) Funde offen")
        } else if isIncomplete {
            title = String(localized: "Nicht vollständig geprüft")
        } else {
            title = String(localized: "Ruhig")
        }
        shield = open > 0 ? .finding : (isIncomplete ? .open : .calm)
        let uncertain = rows.count { !$0.isPreselected }
        let candidates: [SystemVerdict.Item?] = [
            isIncomplete ? SystemVerdict.Item(text: String(localized: "Suche unvollständig"), tone: .neutral) : nil,
            extensionLeftovers > 0 ? SystemVerdict.Item(text: Self.extensionChip(extensionLeftovers), tone: .warning) : nil,
            uncertain > 0 ? SystemVerdict.Item(text: String(localized: "\(uncertain) unsicher"), tone: .neutral) : nil,
        ]
        items = Array(candidates.compactMap(\.self).prefix(Self.maximumItems))
        var parts: [String]
        if findings == 0 {
            parts = [String(localized: "keine Reste")]
        } else {
            parts = [findings == 1 ? String(localized: "1 Fund") : String(localized: "\(findings) Funde")]
            if !rows.isEmpty { parts.append(RemovalSize(rows.map(\.candidate)).text) }
        }
        parts.append(LeftoverSearchStand.timeText(presentation.searchedAt))
        facts = parts.joined(separator: " · ")
    }

    private static func extensionChip(_ count: Int) -> String {
        count == 1 ? String(localized: "1 Erweiterung") : String(localized: "\(count) Erweiterungen")
    }

    private static func extensionsText(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: String(localized: "1 Erweiterung ohne App")
        default: String(localized: "\(count) Erweiterungen ohne App")
        }
    }
}

/// Stand eines Suchergebnisses neben dem Umschalter: vollständig, unvollständig (Orte nicht lesbar oder Abdeckung
/// unvollständig) oder veraltet (Apps seit der Suche geändert oder zu alt; dann ist der Papierkorb gesperrt).
public enum LeftoverSearchStand: Hashable, Sendable {
    case complete, incomplete, outdated

    /// „Suche 14:32“.
    public static func timeText(_ date: Date) -> String {
        String(localized: "Suche \(date.formatted(date: .omitted, time: .shortened))")
    }

    public init(presentation: CleanupPresentation, isOutdated: Bool) {
        if isOutdated {
            self = .outdated
        } else if presentation.coverageNote != nil || presentation.unreadableNote != nil {
            self = .incomplete
        } else {
            self = .complete
        }
    }
}
