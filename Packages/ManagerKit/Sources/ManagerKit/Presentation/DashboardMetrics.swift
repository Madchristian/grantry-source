import Foundation

/// Kennzahlen der Übersicht.
public struct DashboardMetrics: Hashable, Sendable {
    /// Höchstzahl der Einträge in `recentChanges`.
    public static let recentChangesLimit = 5

    /// Verschiedene Drittanbieter-Apps (`AppIdentity.identifier`) mit mindestens einer erteilten Berechtigung;
    /// Apple-Komponenten (`AppleComponent`) zählen nicht.
    public let appsWithAccess: Int
    /// Einträge (Apps, Berechtigungen, Autostart, MCP-Server, Agenten-Freigaben), die in den letzten 7 Tagen
    /// (`RecordBadges.newItemInterval`) hinzugekommen und im Snapshot noch vorhanden sind; ein entfernter und wieder
    /// hinzugefügter Eintrag zählt einmal.
    public let newSince7Days: Int
    /// Auffällige Einträge und Hinweise je Bereich – Quelle von `flaggedCount` und `hintCount` (#275).
    public let flagged: FlaggedBreakdown
    /// Die neuesten Events (höchstens `recentChangesLimit`), neueste zuerst.
    public let recentChanges: [HistoryEvent]

    public init(appsWithAccess: Int, newSince7Days: Int, flagged: FlaggedBreakdown, recentChanges: [HistoryEvent]) {
        self.appsWithAccess = appsWithAccess
        self.newSince7Days = newSince7Days
        self.flagged = flagged
        self.recentChanges = recentChanges
    }

    /// Auffällige Einträge: höchster Befund mittel oder hoch (je Eintrag einmal gezählt) – Summe über die Bereiche.
    public var flaggedCount: Int { flagged.flaggedCount }
    /// Hinweise: Einträge, deren höchster Befund niedrig ist (je Eintrag einmal gezählt) – Summe über die Bereiche.
    public var hintCount: Int { flagged.hintCount }

    /// Ob es überhaupt Befunde gibt (auffällig oder Hinweis).
    public var hasFindings: Bool { flaggedCount + hintCount > 0 }

    /// Unterzeile der Kachel „Auffällig“; nennt die Zahl der Bereiche, wenn mehrere auffällige Einträge haben, und Hinweise
    /// (niedrige Befunde) getrennt.
    public var flaggedCaption: String { captionBase + (hintCount > 0 ? " · \(hintsText)" : "") }

    /// Unterzeile für VoiceOver: wie `flaggedCaption`, aber ausformuliert statt mit Trennpunkt.
    public var flaggedAccessibilityCaption: String {
        let base = flaggedAreaCount > 1 ? "Einträge mit Prüfbedarf in \(flaggedAreaCount) Bereichen" : captionBase
        return base + (hintCount > 0 ? ", dazu \(hintsText) mit niedrigem Risiko" : "")
    }

    /// Bedienhinweis der Kachel „Auffällig“ – passend zu dem, was sie öffnet (`FlaggedBreakdown.tileArea` mit
    /// `tileFilter`); liegen solche Einträge in mehreren Bereichen, führt der Hinweis über der Liste zu den übrigen.
    public var flaggedHint: String {
        let area = flagged.tileArea.title
        let elsewhere = flagged.areas(for: flagged.tileFilter).count > 1
            ? " Ein Hinweis über der Liste führt zu den übrigen Bereichen." : ""
        return switch flagged.tileFilter {
        case .flagged: "Zeigt die auffälligen Einträge in „\(area)“.\(elsewhere)"
        case .withFindings: "Zeigt die Einträge mit Hinweisen in „\(area)“.\(elsewhere)"
        case .all: "Zeigt die Berechtigungen."
        }
    }

    /// Bereiche mit auffälligen Einträgen.
    private var flaggedAreaCount: Int { flagged.areas(for: .flagged).count }

    private var captionBase: String {
        switch (flaggedCount > 0, hintCount > 0) {
        case (true, _): flaggedAreaCount > 1 ? "In \(flaggedAreaCount) Bereichen" : "Einträge mit Prüfbedarf"
        case (false, true): "Keine Auffälligkeiten"
        case (false, false): "Keine Auffälligkeiten gefunden"
        }
    }

    private var hintsText: String { hintCount == 1 ? "1 Hinweis" : "\(hintCount) Hinweise" }

    /// - Parameters:
    ///   - flagged: Aufschlüsselung der Befunde je Bereich (`PresentationSnapshot.make`).
    ///   - events: gespeicherte Events in beliebiger Reihenfolge; die Zahlen beziehen sich nur auf diese.
    public static func compute(
        snapshot: Snapshot, flagged: FlaggedBreakdown, events: [HistoryEvent], now: Date
    ) -> DashboardMetrics {
        DashboardMetrics(
            appsWithAccess: thirdPartyAppsWithAccess(in: snapshot),
            newSince7Days: presentRecentlyAdded(events, in: snapshot, now: now),
            flagged: flagged,
            recentChanges: Array(newestFirst(events).prefix(recentChangesLimit))
        )
    }

    private static func thirdPartyAppsWithAccess(in snapshot: Snapshot) -> Int {
        Set(
            snapshot.grants
                .filter { $0.authValue.isGranted && !AppleComponent.contains($0) }
                .map(\.client.identifier)
        ).count
    }

    private static func presentRecentlyAdded(_ events: [HistoryEvent], in snapshot: Snapshot, now: Date) -> Int {
        let present = Set(snapshot.grants.map(\.id) + snapshot.autostartItems.map(\.id) + snapshot.installedApps.map(\.id))
            .union(snapshot.mcpServers.map(\.id) + snapshot.agentAutoApprovals.map(\.id))
        return Set(events.recentAdditions(now: now).map(\.event.subject.recordID)).intersection(present).count
    }

    /// Nach `detectedAt` absteigend; bei Gleichstand bleibt die Eingabereihenfolge erhalten.
    private static func newestFirst(_ events: [HistoryEvent]) -> [HistoryEvent] {
        events.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.event.detectedAt, rhs.element.event.detectedAt)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
