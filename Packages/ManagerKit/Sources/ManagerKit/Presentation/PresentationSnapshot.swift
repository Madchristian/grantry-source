import Foundation

/// Alles, was die Oberfläche zu einem Monitoring-Zustand anzeigt – einmal je Zustandsänderung berechnet, damit
/// Views nur noch lesen (und höchstens filtern).
public struct PresentationSnapshot: Hashable, Sendable {
    public let appGroups: [AppGroup]
    public let serviceGroups: [ServiceGroup]
    public let autostartSections: [AutostartSection]
    /// Index für `badges(for:)` je Listenzeile.
    public let badges: RecordBadges
    public let cleanupHints: [CleanupHint]
    public let metrics: DashboardMetrics
    /// Bereich „Sicherheit“, Kachel und Popover-Statuszeile.
    public let security: SecurityOverview
    /// Installierte Apps nach Name (wie im Finder); Filter und Sortierung: `AppInventoryPresenter`.
    public let installedApps: [InstalledApp]
    /// Scan-Abdeckung je Inventarbereich (#142): Hinweis über jeder Liste, leere Zustände, Übersicht und Menüleiste.
    public let coverage: CoverageOverview
    /// Bereich „Netzwerk“: Lauscher, Firewall und „Gestartet von“ (Quellenhinweise: `coverage`).
    public let network: NetworkOverview
    public let agents: AgentPresentationState
    private let appLinksByID: [String: AppLinks]
    private let findingsByRecordID: [String: [RiskFinding]]
    private let cleanupHintsByRecordID: [String: CleanupHint]
    /// launchd-Einträge je `AutostartItem.launchdServiceID` – nur Dienste mit mehr als einer Plist (#138).
    private let sharedServices: [String: [AutostartItem]]

    /// Findings zu einem Eintrag, höchster Schweregrad zuerst.
    public func findings(for recordID: String) -> [RiskFinding] { findingsByRecordID[recordID] ?? [] }

    /// Die übrigen Plists, die denselben launchd-Dienst wie `item` beschreiben – gleiches Label in derselben Domain
    /// (`AutostartItem.launchdServiceID`, #138); leer, wenn `item` der einzige ist.
    public func autostartItems(sharingServiceWith item: AutostartItem) -> [AutostartItem] {
        item.launchdServiceID.flatMap { sharedServices[$0] }?.filter { $0.id != item.id } ?? []
    }

    /// Aufräumhinweis zu einem Eintrag, falls vorhanden.
    public func cleanupHint(for recordID: String) -> CleanupHint? { cleanupHintsByRecordID[recordID] }

    /// Höchster Schweregrad der Findings zu einem Eintrag; `nil` ohne Findings.
    public func highestSeverity(for recordID: String) -> RiskFinding.Severity? {
        findings(for: recordID).first?.severity
    }

    /// Berechtigungen und Autostart-Einträge einer App (`AppLinks`).
    public func links(for app: InstalledApp) -> AppLinks {
        appLinksByID[app.id] ?? AppLinks(grants: [], autostartItems: [])
    }

    /// Angaben im App-Detail mit den Befunden und Verknüpfungen der App.
    /// - Parameter details: nachgeladene Angaben (`AppDetailsLoader`); `nil`, solange sie geladen werden.
    public func detail(
        for app: InstalledApp, details: AppUsageDetails?, now: Date, calendar: Calendar = .current,
        home: String = NSHomeDirectory()
    ) -> InstalledAppDetail {
        InstalledAppDetail(app: app, details: details, findings: findings(for: app.id), links: links(for: app), now: now,
                           calendar: calendar, home: home)
    }

    /// Höchster Schweregrad aller Findings (Berechtigungen, Autostart-Einträge, Apps, Agenten und Lauscher); `nil` ohne Findings.
    public var highestSeverity: RiskFinding.Severity? {
        (serviceGroups.map(\.highestSeverity) + autostartSections.map(\.highestSeverity)
            + [appsHighestSeverity, agentsHighestSeverity, networkHighestSeverity])
            .compactMap(\.self).max()
    }

    /// Bereich, den die Kachel „Auffällig“ öffnet (`FlaggedBreakdown.tileArea`).
    public var flaggedArea: FlaggedArea { metrics.flagged.tileArea }

    private var appsHighestSeverity: RiskFinding.Severity? {
        installedApps.compactMap { highestSeverity(for: $0.id) }.max()
    }

    private var networkHighestSeverity: RiskFinding.Severity? {
        network.listeners.compactMap { highestSeverity(for: $0.id) }.max()
    }

    /// - Parameters:
    ///   - activeSources: Quellen, die ein Vollscan fragt (`MonitoringState.activeSources`); `nil`: alle. Bestimmt die
    ///     erwartete Abdeckung je Bereich (`CoverageOverview`).
    ///   - events: die jüngsten Events (z. B. `MonitoringState.recentEvents`).
    ///   - recentAdditions: `.added`-Events der letzten 7 Tage (`SnapshotStore.additions(since:)`); ergänzt
    ///     `events` für „neu“, Dubletten (gleiche `HistoryEvent.id`) zählen einmal.
    public static func make(
        snapshot: Snapshot, findings: [RiskFinding], events: [HistoryEvent], recentAdditions: [HistoryEvent],
        activeSources: Set<SourceID>? = nil, now: Date
    ) -> PresentationSnapshot {
        let knownIDs = Set(events.map(\.id))
        let allEvents = events + recentAdditions.filter { !knownIDs.contains($0.id) }
        let cleanupHints = CleanupHints.evaluate(snapshot)
        let serviceGroups = InventoryPresenter.serviceGroups(snapshot: snapshot, findings: findings)
        let autostartSections = InventoryPresenter.autostartSections(snapshot: snapshot, findings: findings)
        let installedApps = snapshot.installedApps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let network = NetworkOverview.make(snapshot: snapshot)
        let agents = AgentPresentationState(snapshot: snapshot)
        // Je Bereich genau die Einträge, die seine Liste zeigt (#275).
        let flagged = FlaggedBreakdown(
            recordIDs: [
                .permissions: serviceGroups.flatMap(\.grants).map(\.id),
                .autostart: autostartSections.flatMap(\.items).map(\.id),
                .apps: installedApps.map(\.id),
                .agents: agents.groups.flatMap(\.recordIDs),
                .network: NetworkListenerPresenter.rows(
                    network.listeners, severity: { _ in nil }, query: "", filter: .flagged
                ).map(\.id),
            ],
            severities: SeverityIndex(findings)
        )
        return PresentationSnapshot(
            appGroups: InventoryPresenter.appGroups(snapshot: snapshot, findings: findings),
            serviceGroups: serviceGroups,
            autostartSections: autostartSections,
            badges: RecordBadges(findings: findings, events: allEvents, cleanupHints: cleanupHints, now: now),
            cleanupHints: cleanupHints,
            metrics: DashboardMetrics.compute(snapshot: snapshot, flagged: flagged, events: allEvents, now: now),
            security: SecurityOverview.make(checks: snapshot.securityChecks, now: now),
            installedApps: installedApps,
            coverage: CoverageOverview(snapshot: snapshot, activeSources: activeSources),
            network: network,
            agents: agents,
            appLinksByID: AppLinks.index(snapshot.installedApps, in: snapshot),
            findingsByRecordID: Dictionary(grouping: findings, by: \.recordID).mapValues { findings in
                findings.enumerated()
                    .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
                    .map(\.element)
            },
            cleanupHintsByRecordID: Dictionary(cleanupHints.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first }),
            sharedServices: Dictionary(
                snapshot.autostartItems.filter { $0.source == .launchd }
                    .compactMap { item in item.launchdServiceID.map { ($0, [item]) } },
                uniquingKeysWith: +
            ).filter { $0.value.count > 1 }
        )
    }
}
