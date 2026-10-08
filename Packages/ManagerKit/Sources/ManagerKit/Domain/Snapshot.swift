import Foundation

/// Gesamtzustand aller Quellen zu einem Zeitpunkt.
/// Pflicht je Eintragsart: `removingRecords(of:)`, `carryingForwardRecords`, `isEquivalent`, `derivedBaselineSources`.
public struct Snapshot: Hashable, Sendable, Codable {
    public var takenAt: Date
    public var grants: [PermissionGrant]
    public var autostartItems: [AutostartItem]
    public var securityChecks: [SecurityCheck]
    public var installedApps: [InstalledApp]
    public var networkListeners: [NetworkListener]
    public var mcpServers: [MCPServerEntry]
    public var agentAutoApprovals: [AgentAutoApproval]
    public var sourceErrors: [SourceError]
    /// Einschränkungen von Quellen, die trotzdem geliefert haben (Review M2) – nur Hinweis, zählt nicht für
    /// `isEquivalent(to:)`.
    public var sourceLimitations: [SourceLimitation]
    /// Quellen, die **jemals** erfolgreich geliefert haben. Liefert eine Quelle zum ersten Mal, sind ihre Einträge
    /// Baseline: `SnapshotDiffer` erzeugt für sie keine `.added`-Events.
    public var baselineSources: Set<SourceID>
    /// Die Lauscher-Quelle hat **jemals** vollständig geliefert (alle Benutzer über den Helper, ohne Einschränkung).
    /// Erst die erste vollständige Lieferung ist Baseline für Lauscher anderer Benutzer (`NetworkListenerBaseline`);
    /// danach meldet jede weitere neue fremde Lauscher – auch nach einem zwischenzeitlichen Helper-Ausfall. Wird wie
    /// `baselineSources` fortgeschrieben und zählt für `isEquivalent(to:)`, damit er gespeichert wird.
    public var hasCompleteListenerBaseline: Bool
    /// Beginn des Scans, in dem jede Quelle zuletzt geliefert hat – auch eingeschränkt (#142). Fällt eine Quelle aus,
    /// bleibt ihr Zeitpunkt stehen: Er ist das Alter ihrer fortgeschriebenen Einträge („letzter bekannter Stand“).
    /// Nur Anzeige, zählt nicht für `isEquivalent(to:)`; ältere Snapshots kennen ihn nicht (leer).
    public var lastDeliveryBySource: [SourceID: Date]
    /// Beginn des Scans der letzten Zwischenmessung je Quelle – einer Lieferung, die nicht den vollen Umfang abdeckt
    /// (`InventoryContribution.coversFullScope == false`, etwa eigene Lauscher zwischen den Helper-Abfragen). Entfällt
    /// mit der nächsten vollständigen Lieferung. Nur Anzeige, zählt nicht für `isEquivalent(to:)`.
    public var lastInterimDeliveryBySource: [SourceID: Date]

    /// - Parameter baselineSources: `nil` leitet die Baseline aus den Quellen der übergebenen Einträge ab
    ///   (siehe `derivedBaselineSources`).
    public init(
        takenAt: Date,
        grants: [PermissionGrant],
        autostartItems: [AutostartItem],
        securityChecks: [SecurityCheck] = [],
        installedApps: [InstalledApp] = [],
        networkListeners: [NetworkListener] = [],
        mcpServers: [MCPServerEntry] = [],
        agentAutoApprovals: [AgentAutoApproval] = [],
        sourceErrors: [SourceError],
        sourceLimitations: [SourceLimitation] = [],
        baselineSources: Set<SourceID>? = nil,
        hasCompleteListenerBaseline: Bool = false,
        lastDeliveryBySource: [SourceID: Date] = [:],
        lastInterimDeliveryBySource: [SourceID: Date] = [:]
    ) {
        self.takenAt = takenAt
        self.grants = grants
        self.autostartItems = autostartItems
        self.securityChecks = securityChecks
        self.installedApps = installedApps
        self.networkListeners = networkListeners
        self.mcpServers = mcpServers
        self.agentAutoApprovals = agentAutoApprovals
        self.sourceErrors = sourceErrors
        self.sourceLimitations = sourceLimitations
        self.baselineSources = baselineSources
            ?? Self.derivedBaselineSources(
                grants: grants, autostartItems: autostartItems, securityChecks: securityChecks, installedApps: installedApps,
                networkListeners: networkListeners, mcpServers: mcpServers, agentAutoApprovals: agentAutoApprovals
            )
        self.hasCompleteListenerBaseline = hasCompleteListenerBaseline
        self.lastDeliveryBySource = lastDeliveryBySource
        self.lastInterimDeliveryBySource = lastInterimDeliveryBySource
    }

    private enum CodingKeys: String, CodingKey {
        case takenAt, grants, autostartItems, securityChecks, installedApps, networkListeners, sourceErrors, sourceLimitations, baselineSources
        case mcpServers, agentAutoApprovals, hasCompleteListenerBaseline, lastDeliveryBySource
        case lastInterimDeliveryBySource
    }

    /// Ältere Snapshots: ohne `baselineSources` die abgeleitete Baseline, ohne `securityChecks` keine Prüfungen, ohne
    /// `installedApps` keine Apps, ohne `networkListeners` keine Lauscher, ohne `sourceLimitations` keine Einschränkungen,
    /// ohne Agenten-Felder keine MCP-Server/Freigaben, ohne `hasCompleteListenerBaseline` keine vollständige
    /// Lauscher-Baseline (die nächste vollständige Lieferung gilt dann einmal als Baseline), ohne `lastDeliveryBySource`
    /// keine Lieferzeitpunkte und Zwischenmessungen.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            takenAt: try container.decode(Date.self, forKey: .takenAt),
            grants: try container.decode([PermissionGrant].self, forKey: .grants),
            autostartItems: try container.decode([AutostartItem].self, forKey: .autostartItems),
            securityChecks: try container.decodeIfPresent([SecurityCheck].self, forKey: .securityChecks) ?? [],
            installedApps: try container.decodeIfPresent([InstalledApp].self, forKey: .installedApps) ?? [],
            networkListeners: try container.decodeIfPresent([NetworkListener].self, forKey: .networkListeners) ?? [],
            mcpServers: try container.decodeIfPresent([MCPServerEntry].self, forKey: .mcpServers) ?? [],
            agentAutoApprovals: try container.decodeIfPresent([AgentAutoApproval].self, forKey: .agentAutoApprovals) ?? [],
            sourceErrors: try container.decode([SourceError].self, forKey: .sourceErrors),
            sourceLimitations: try container.decodeIfPresent([SourceLimitation].self, forKey: .sourceLimitations) ?? [],
            baselineSources: try container.decodeIfPresent(Set<SourceID>.self, forKey: .baselineSources),
            hasCompleteListenerBaseline: try container.decodeIfPresent(Bool.self, forKey: .hasCompleteListenerBaseline)
                ?? false,
            lastDeliveryBySource: try container.decodeIfPresent([SourceID: Date].self, forKey: .lastDeliveryBySource) ?? [:],
            lastInterimDeliveryBySource: try container.decodeIfPresent(
                [SourceID: Date].self, forKey: .lastInterimDeliveryBySource
            ) ?? [:]
        )
    }

    /// Quellen, die offensichtlich schon geliefert haben, weil Einträge von ihnen vorliegen.
    private static func derivedBaselineSources(
        grants: [PermissionGrant], autostartItems: [AutostartItem], securityChecks: [SecurityCheck],
        installedApps: [InstalledApp], networkListeners: [NetworkListener],
        mcpServers: [MCPServerEntry], agentAutoApprovals: [AgentAutoApproval]
    ) -> Set<SourceID> {
        Set(grants.map(\.source) + autostartItems.map(\.source) + securityChecks.map(\.source)
            + installedApps.map(\.source) + networkListeners.map(\.source)
            + mcpServers.map(\.source) + agentAutoApprovals.map(\.source))
    }

    public var failedSources: Set<SourceID> { Set(sourceErrors.map(\.source)) }

    /// `true`, wenn sich `other` für den Nutzer nicht von diesem Snapshot unterscheidet: gleiche ID-Mengen je Typ,
    /// keine signifikanten Änderungen (`hasSignificantChanges`), gleiche fehlgeschlagene Quellen und gleiche Baseline.
    /// Reihenfolge, Zeitstempel und Fehlertexte spielen keine Rolle. Die Baseline (auch `hasCompleteListenerBaseline`)
    /// zählt mit, damit eine erstmals liefernde Quelle gespeichert wird – sonst gälte ihre nächste Lieferung erneut als
    /// Baseline.
    public func isEquivalent(to other: Snapshot) -> Bool {
        failedSources == other.failedSources
            && baselineSources == other.baselineSources
            && hasCompleteListenerBaseline == other.hasCompleteListenerBaseline
            && Self.recordsAreEquivalent(grants, other.grants)
            && Self.recordsAreEquivalent(autostartItems, other.autostartItems)
            && Self.recordsAreEquivalent(securityChecks, other.securityChecks)
            && Self.recordsAreEquivalent(installedApps, other.installedApps)
            && Self.recordsAreEquivalent(networkListeners, other.networkListeners)
            && Self.recordsAreEquivalent(mcpServers, other.mcpServers)
            && Self.recordsAreEquivalent(agentAutoApprovals, other.agentAutoApprovals)
    }

    /// Übernimmt für jede in diesem Snapshot fehlgeschlagene Quelle die Einträge je Typ aus `previous`,
    /// damit der gespeicherte Snapshot den letzten bekannten Zustand behält. Idempotent: Einträge, deren `id`
    /// bereits vorhanden ist, werden nicht erneut übernommen. `baselineSources` bleibt unverändert.
    public func carryingForwardRecords(ofFailedSourcesFrom previous: Snapshot?) -> Snapshot {
        let failed = failedSources
        guard let previous, !failed.isEmpty else { return self }
        var result = self
        result.grants += Self.missingRecords(of: failed, from: previous.grants, in: grants)
        result.autostartItems += Self.missingRecords(of: failed, from: previous.autostartItems, in: autostartItems)
        result.securityChecks += Self.missingRecords(of: failed, from: previous.securityChecks, in: securityChecks)
        result.installedApps += Self.missingRecords(of: failed, from: previous.installedApps, in: installedApps)
        result.networkListeners += Self.missingRecords(of: failed, from: previous.networkListeners, in: networkListeners)
        result.mcpServers += Self.missingRecords(of: failed, from: previous.mcpServers, in: mcpServers)
        result.agentAutoApprovals += Self.missingRecords(of: failed, from: previous.agentAutoApprovals, in: agentAutoApprovals)
        return result
    }

    /// Einträge aus `previous`, die von einer Quelle in `failed` stammen und deren `id` in `current` fehlt.
    private static func missingRecords<Record: InventoryRecord>(
        of failed: Set<SourceID>, from previous: [Record], in current: [Record]
    ) -> [Record] {
        let present = Set(current.map(\.id))
        return previous.filter { failed.contains($0.source) && !present.contains($0.id) }
    }

    /// Gleiche ID-Mengen und kein Paar mit signifikanter Änderung; bei doppelten IDs gilt wie im Differ der erste Eintrag.
    private static func recordsAreEquivalent<Record: InventoryRecord>(_ lhs: [Record], _ rhs: [Record]) -> Bool {
        let lhsByID = lhs.firstByID()
        let rhsByID = rhs.firstByID()
        guard Set(lhsByID.keys) == Set(rhsByID.keys) else { return false }
        return lhsByID.allSatisfy { id, record in
            rhsByID[id].map { !record.hasSignificantChanges(comparedTo: $0) } ?? false
        }
    }
}

extension Array where Element: InventoryRecord {
    /// Einträge nach `id`; bei doppelten IDs gewinnt der erste Eintrag.
    func firstByID() -> [String: Element] {
        Dictionary(map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
