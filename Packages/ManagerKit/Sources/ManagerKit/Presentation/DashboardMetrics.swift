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
    /// Auffällige Einträge: höchster Befund mittel oder hoch (je Eintrag einmal gezählt).
    public let flaggedCount: Int
    /// Hinweise: Einträge, deren höchster Befund niedrig ist (je Eintrag einmal gezählt).
    public let hintCount: Int
    /// Die neuesten Events (höchstens `recentChangesLimit`), neueste zuerst.
    public let recentChanges: [HistoryEvent]

    public init(appsWithAccess: Int, newSince7Days: Int, flaggedCount: Int, hintCount: Int, recentChanges: [HistoryEvent]) {
        self.appsWithAccess = appsWithAccess
        self.newSince7Days = newSince7Days
        self.flaggedCount = flaggedCount
        self.hintCount = hintCount
        self.recentChanges = recentChanges
    }

    /// Ob es überhaupt Befunde gibt (auffällig oder Hinweis).
    public var hasFindings: Bool { flaggedCount + hintCount > 0 }

    /// Unterzeile der Kachel „Auffällig“; nennt Hinweise (niedrige Befunde) getrennt.
    public var flaggedCaption: String { captionBase + (hintCount > 0 ? " · \(hintsText)" : "") }

    /// Unterzeile für VoiceOver: wie `flaggedCaption`, aber ausformuliert statt mit Trennpunkt.
    public var flaggedAccessibilityCaption: String {
        captionBase + (hintCount > 0 ? ", dazu \(hintsText) mit niedrigem Risiko" : "")
    }

    /// Bedienhinweis der Kachel „Auffällig“ – passend zu dem, was sie öffnet (`PresentationSnapshot.flaggedArea`).
    public var flaggedHint: String {
        switch (flaggedCount > 0, hintCount > 0) {
        case (true, _): "Zeigt nur die auffälligen Einträge."
        case (false, true): "Zeigt die Einträge mit Hinweisen."
        case (false, false): "Zeigt die Berechtigungen."
        }
    }

    private var captionBase: String {
        switch (flaggedCount > 0, hintCount > 0) {
        case (true, _): "Einträge mit Prüfbedarf"
        case (false, true): "Keine Auffälligkeiten"
        case (false, false): "Keine Auffälligkeiten gefunden"
        }
    }

    private var hintsText: String { hintCount == 1 ? "1 Hinweis" : "\(hintCount) Hinweise" }

    /// - Parameter events: gespeicherte Events in beliebiger Reihenfolge; die Zahlen beziehen sich nur auf diese.
    public static func compute(
        snapshot: Snapshot, findings: [RiskFinding], events: [HistoryEvent], now: Date
    ) -> DashboardMetrics {
        let severities = SeverityIndex(findings)
        return DashboardMetrics(
            appsWithAccess: thirdPartyAppsWithAccess(in: snapshot),
            newSince7Days: presentRecentlyAdded(events, in: snapshot, now: now),
            flaggedCount: severities.recordIDs { $0 >= .medium }.count,
            hintCount: severities.recordIDs { $0 == .low }.count,
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
