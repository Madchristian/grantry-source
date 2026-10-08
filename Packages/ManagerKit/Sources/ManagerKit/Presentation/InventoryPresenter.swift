import Foundation

// MARK: - Gruppen

/// Eine App mit ihren Berechtigungen und den Autostart-Einträgen, die ihr gehören.
public struct AppGroup: Identifiable, Hashable, Sendable {
    public let app: AppIdentity
    /// Nach Auffälligkeit, dann Dienstname sortiert.
    public let grants: [PermissionGrant]
    /// Nach Auffälligkeit, dann Label sortiert.
    public let autostartItems: [AutostartItem]
    let severities: SeverityIndex

    /// `AppIdentity.identifier`.
    public var id: String { app.identifier }
    /// Höchster Schweregrad der Findings zu den Einträgen der Gruppe; `nil`, wenn keiner auffällig ist.
    public var highestSeverity: RiskFinding.Severity? { severities.highest }
    public var isFlagged: Bool { highestSeverity != nil }

    /// Höchster Schweregrad der Findings zu einem Eintrag der Gruppe.
    public func severity(of recordID: String) -> RiskFinding.Severity? { severities.severity(of: recordID) }

    init(app: AppIdentity, grants: [PermissionGrant], autostartItems: [AutostartItem], severities: SeverityIndex) {
        self.init(
            app: app,
            sortedGrants: PresentationOrder.sorted(grants, severities: severities, name: \.serviceDisplayName),
            sortedItems: PresentationOrder.sorted(autostartItems, severities: severities, name: \.label),
            severities: severities
        )
    }

    /// Übernimmt bereits sortierte Einträge (etwa nach dem Filtern) ohne erneute Sortierung.
    init(app: AppIdentity, sortedGrants: [PermissionGrant], sortedItems: [AutostartItem], severities: SeverityIndex) {
        self.app = app
        self.severities = severities.restricted(to: sortedGrants.map(\.id) + sortedItems.map(\.id))
        self.grants = sortedGrants
        self.autostartItems = sortedItems
    }
}

/// Eine Berechtigungsart mit den Berechtigungen aller Apps.
public struct ServiceGroup: Identifiable, Hashable, Sendable {
    public let service: PermissionService
    /// Nach Auffälligkeit, dann App-Name sortiert.
    public let grants: [PermissionGrant]
    let severities: SeverityIndex

    /// TCC-Service-ID.
    public var id: String { service.id }
    public var highestSeverity: RiskFinding.Severity? { severities.highest }
    public var isFlagged: Bool { highestSeverity != nil }

    public func severity(of recordID: String) -> RiskFinding.Severity? { severities.severity(of: recordID) }

    init(service: PermissionService, grants: [PermissionGrant], severities: SeverityIndex) {
        let sorted = PresentationOrder.sorted(grants, severities: severities, name: \.client.displayName)
        self.init(service: service, sortedGrants: sorted, severities: severities)
    }

    /// Übernimmt bereits sortierte Berechtigungen ohne erneute Sortierung.
    init(service: PermissionService, sortedGrants: [PermissionGrant], severities: SeverityIndex) {
        self.service = service
        self.severities = severities.restricted(to: sortedGrants.map(\.id))
        self.grants = sortedGrants
    }
}

/// Autostart-Einträge einer Art.
public struct AutostartSection: Identifiable, Hashable, Sendable {
    public let kind: AutostartKind
    /// Nach Auffälligkeit, dann Label sortiert.
    public let items: [AutostartItem]
    let severities: SeverityIndex

    public var id: AutostartKind { kind }
    /// Deutscher Abschnittstitel (`AutostartKind.sectionTitle`).
    public var title: String { kind.sectionTitle }
    public var highestSeverity: RiskFinding.Severity? { severities.highest }
    public var isFlagged: Bool { highestSeverity != nil }

    public func severity(of recordID: String) -> RiskFinding.Severity? { severities.severity(of: recordID) }

    init(kind: AutostartKind, items: [AutostartItem], severities: SeverityIndex) {
        let sorted = PresentationOrder.sorted(items, severities: severities, name: \.label)
        self.init(kind: kind, sortedItems: sorted, severities: severities)
    }

    /// Übernimmt bereits sortierte Einträge ohne erneute Sortierung.
    init(kind: AutostartKind, sortedItems: [AutostartItem], severities: SeverityIndex) {
        self.kind = kind
        self.severities = severities.restricted(to: sortedItems.map(\.id))
        self.items = sortedItems
    }
}

extension AutostartKind {
    /// Deutscher Titel eines Abschnitts mit Einträgen dieser Art.
    public var sectionTitle: String {
        switch self {
        case .loginItem: "Anmeldeobjekte"
        case .launchAgent: "LaunchAgents"
        case .launchDaemon: "LaunchDaemons"
        case .backgroundTask: "Hintergrundobjekte"
        }
    }
}

// MARK: - Filter

/// Liste, in der ein Filter angeboten wird; bestimmt seine Beschriftung.
public enum FilterContext: Hashable, Sendable {
    case permissions, autostart
}

/// Filter nach Zustand: Berechtigungen erteilt (`AuthValue.isGranted`) bzw. nicht; Autostart-Einträge aktiviert
/// bzw. deaktiviert.
public enum GrantStateFilter: String, Hashable, Sendable, CaseIterable {
    case all, allowed, denied

    /// „Erlaubt“/„Verweigert“ bei Berechtigungen, „Aktiviert“/„Deaktiviert“ bei Autostart-Einträgen.
    public func title(for context: FilterContext) -> String {
        switch (self, context) {
        case (.all, _): "Alle"
        case (.allowed, .permissions): "Erlaubt"
        case (.denied, .permissions): "Verweigert"
        case (.allowed, .autostart): "Aktiviert"
        case (.denied, .autostart): "Deaktiviert"
        }
    }

    fileprivate func matches(isAllowed: Bool) -> Bool {
        switch self {
        case .all: true
        case .allowed: isAllowed
        case .denied: !isAllowed
        }
    }
}

/// Filter nach Bereich: `TCCScope` bei Berechtigungen, `AutostartDomain` bei Autostart-Einträgen.
public enum ScopeFilter: String, Hashable, Sendable, CaseIterable {
    case all, user, system

    public var title: String {
        switch self {
        case .all: "Alle"
        case .user: "Benutzer"
        case .system: "System"
        }
    }

    fileprivate func matches(_ scope: TCCScope) -> Bool {
        switch (self, scope) {
        case (.all, _), (.user, .user), (.system, .system): true
        case (.user, .system), (.system, .user): false
        }
    }

    fileprivate func matches(_ domain: AutostartDomain) -> Bool {
        switch (self, domain) {
        case (.all, _), (.user, .user), (.system, .system): true
        case (.user, .system), (.system, .user): false
        }
    }
}

/// Filterkriterien für die Listen; ein Eintrag bleibt, wenn er alle Kriterien erfüllt.
struct InventoryFilter: Sendable {
    let query: String
    let state: GrantStateFilter
    let scope: ScopeFilter
    let onlyFlagged: Bool

    init(query: String, state: GrantStateFilter, scope: ScopeFilter, onlyFlagged: Bool) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.state = state
        self.scope = scope
        self.onlyFlagged = onlyFlagged
    }

    /// Suche über App-Name, Bundle-ID bzw. Pfad des Clients und Dienstname.
    func matches(_ grant: PermissionGrant, severities: SeverityIndex) -> Bool {
        state.matches(isAllowed: grant.authValue.isGranted)
            && scope.matches(grant.scope)
            && flagMatches(grant.id, severities)
            && queryMatches([grant.client.displayName, grant.client.bundleID, grant.clientID, grant.serviceDisplayName])
    }

    /// Suche über Label sowie Name und Bundle-ID der zugehörigen App.
    func matches(_ item: AutostartItem, severities: SeverityIndex) -> Bool {
        state.matches(isAllowed: item.isEnabled)
            && scope.matches(item.domain)
            && flagMatches(item.id, severities)
            && queryMatches([item.label, item.owner?.displayName, item.owner?.bundleID])
    }

    private func flagMatches(_ recordID: String, _ severities: SeverityIndex) -> Bool {
        !onlyFlagged || severities.severity(of: recordID) != nil
    }

    /// Ohne Groß-/Kleinschreibung und diakritische Zeichen; eine leere Suche passt immer.
    private func queryMatches(_ fields: [String?]) -> Bool {
        query.isEmpty || fields.contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

// MARK: - Presenter

/// Bereitet einen Snapshot für die Listen auf: Gruppierung, Sortierung und Filter. Reine Funktionen.
public enum InventoryPresenter {
    /// Berechtigungen und Autostart-Einträge je App. Autostart-Einträge ohne bekannte App erscheinen nur in
    /// `autostartSections`. Sortiert: auffällige Apps zuerst (höchster Schweregrad absteigend), dann Name.
    public static func appGroups(snapshot: Snapshot, findings: [RiskFinding]) -> [AppGroup] {
        let severities = SeverityIndex(findings)
        let grantsByApp = Dictionary(grouping: snapshot.grants, by: \.client.identifier)
        let ownedItems = snapshot.autostartItems.compactMap { item in item.owner.map { (owner: $0, item: item) } }
        let itemsByApp = Dictionary(grouping: ownedItems, by: \.owner.identifier)
        // Vertreter je App: erster Client bzw. Eigentümer in Snapshot-Reihenfolge.
        var apps: [String: AppIdentity] = [:]
        for app in snapshot.grants.map(\.client) + ownedItems.map(\.owner) where apps[app.identifier] == nil {
            apps[app.identifier] = app
        }
        let groups = apps.map { identifier, app in
            AppGroup(
                app: app, grants: grantsByApp[identifier] ?? [], autostartItems: itemsByApp[identifier]?.map(\.item) ?? [],
                severities: severities
            )
        }
        return sorted(groups)
    }

    /// Berechtigungen je TCC-Service. Sortiert: auffällige Dienste zuerst, dann Anzeigename.
    public static func serviceGroups(snapshot: Snapshot, findings: [RiskFinding]) -> [ServiceGroup] {
        let severities = SeverityIndex(findings)
        let groups = Dictionary(grouping: snapshot.grants, by: \.service).map { service, grants in
            ServiceGroup(service: PermissionCatalog.service(for: service), grants: grants, severities: severities)
        }
        return sorted(groups)
    }

    /// Autostart-Einträge je Art in der Reihenfolge von `AutostartKind.allCases`; leere Arten entfallen.
    public static func autostartSections(snapshot: Snapshot, findings: [RiskFinding]) -> [AutostartSection] {
        let severities = SeverityIndex(findings)
        let itemsByKind = Dictionary(grouping: snapshot.autostartItems, by: \.kind)
        return AutostartKind.allCases.compactMap { kind in
            itemsByKind[kind].map { AutostartSection(kind: kind, items: $0, severities: severities) }
        }
    }

    /// Behält je Gruppe nur passende Einträge; Gruppen ohne Einträge entfallen, die Sortierung wird neu bestimmt.
    public static func filter(
        _ groups: [AppGroup], query: String = "", state: GrantStateFilter = .all, scope: ScopeFilter = .all,
        onlyFlagged: Bool = false
    ) -> [AppGroup] {
        let filter = InventoryFilter(query: query, state: state, scope: scope, onlyFlagged: onlyFlagged)
        let filtered = groups.compactMap { group -> AppGroup? in
            let grants = group.grants.filter { filter.matches($0, severities: group.severities) }
            let items = group.autostartItems.filter { filter.matches($0, severities: group.severities) }
            guard !grants.isEmpty || !items.isEmpty else { return nil }
            return AppGroup(app: group.app, sortedGrants: grants, sortedItems: items, severities: group.severities)
        }
        return sorted(filtered)
    }

    /// Wie `filter(_:query:state:scope:onlyFlagged:)` für Gruppen nach Berechtigung.
    public static func filter(
        _ groups: [ServiceGroup], query: String = "", state: GrantStateFilter = .all, scope: ScopeFilter = .all,
        onlyFlagged: Bool = false
    ) -> [ServiceGroup] {
        let filter = InventoryFilter(query: query, state: state, scope: scope, onlyFlagged: onlyFlagged)
        let filtered = groups.compactMap { group -> ServiceGroup? in
            let grants = group.grants.filter { filter.matches($0, severities: group.severities) }
            guard !grants.isEmpty else { return nil }
            return ServiceGroup(service: group.service, sortedGrants: grants, severities: group.severities)
        }
        return sorted(filtered)
    }

    /// Wie `filter(_:query:state:scope:onlyFlagged:)` für Autostart-Abschnitte; deren Reihenfolge bleibt erhalten.
    public static func filter(
        _ sections: [AutostartSection], query: String = "", state: GrantStateFilter = .all, scope: ScopeFilter = .all,
        onlyFlagged: Bool = false
    ) -> [AutostartSection] {
        let filter = InventoryFilter(query: query, state: state, scope: scope, onlyFlagged: onlyFlagged)
        return sections.compactMap { section in
            let items = section.items.filter { filter.matches($0, severities: section.severities) }
            guard !items.isEmpty else { return nil }
            return AutostartSection(kind: section.kind, sortedItems: items, severities: section.severities)
        }
    }

    private static func sorted(_ groups: [AppGroup]) -> [AppGroup] {
        PresentationOrder.sorted(groups, severity: \.highestSeverity, name: \.app.displayName, id: \.id)
    }

    private static func sorted(_ groups: [ServiceGroup]) -> [ServiceGroup] {
        PresentationOrder.sorted(groups, severity: \.highestSeverity, name: \.service.displayName, id: \.id)
    }
}

// MARK: - Sortierung

/// Einheitliche, deterministische Listenreihenfolge: höchster Schweregrad zuerst, dann Name (ohne Groß-/Kleinschreibung,
/// Zahlen numerisch), zuletzt die ID.
enum PresentationOrder {
    /// Sortierschlüssel werden je Element einmal berechnet, nicht bei jedem Vergleich.
    static func sorted<Element>(
        _ elements: [Element], severity: (Element) -> RiskFinding.Severity?, name: (Element) -> String,
        id: (Element) -> String
    ) -> [Element] {
        elements
            .map { (element: $0, severity: severity($0)?.rawValue ?? 0, name: name($0), id: id($0)) }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id < rhs.id
            }
            .map(\.element)
    }

    static func sorted<Record: InventoryRecord>(
        _ records: [Record], severities: SeverityIndex, name: (Record) -> String
    ) -> [Record] {
        sorted(records, severity: { severities.severity(of: $0.id) }, name: name, id: \.id)
    }
}

extension PermissionGrant {
    /// Anzeigename des Dienstes laut `PermissionCatalog`.
    var serviceDisplayName: String { PermissionCatalog.service(for: service).displayName }
}
