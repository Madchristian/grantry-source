import Foundation

/// Art einer Sicherheitsprüfung (Spec v2 §2); der Rohwert ist die `id` des `SecurityCheck`. Die Reihenfolge der Fälle
/// ist die Anzeigereihenfolge.
public enum SecurityCheckKind: String, Hashable, Sendable, Codable, CaseIterable {
    case fileVault, firewall, sip, gatekeeper, xprotect, automaticUpdates, pendingUpdates, mdmEnrollment
}

/// Ampel einer Prüfung. `unknown`: nicht lesbar oder unbekanntes Format – nie „kritisch“.
public enum SecurityState: String, Hashable, Sendable, Codable {
    case good, warning, critical, unknown

    /// Schwere für Verschlechterungen; `unknown` hat keine.
    private var severity: Int? {
        switch self {
        case .good: 0
        case .warning: 1
        case .critical: 2
        case .unknown: nil
        }
    }

    /// `true` bei good→warning/critical und warning→critical; mit `unknown` auf einer Seite nie.
    public func isDeterioration(from previous: SecurityState) -> Bool {
        guard let old = previous.severity, let new = severity else { return false }
        return new > old
    }

    /// Rang für „schlechteste Ampel“ (Kachel): good < unknown < warning < critical.
    public var displayRank: Int {
        switch self {
        case .good: 0
        case .unknown: 1
        case .warning: 2
        case .critical: 3
        }
    }
}

public enum FileVaultStatus: String, Hashable, Sendable, Codable {
    case on, off, encrypting, decrypting, pendingRestart
}

public enum SIPStatus: String, Hashable, Sendable, Codable {
    case enabled, customConfiguration, disabled
}

/// Ein empfohlenes, noch nicht installiertes Update.
public struct PendingUpdate: Hashable, Sendable, Codable, Identifiable {
    public var identifier: String
    public var displayName: String
    public var displayVersion: String?
    /// Beginn „ausstehend“: erstes Angebot laut Plist (`FirstOfferDateDictionary`), sonst erster Scan mit diesem
    /// `identifier`; über Scans hinweg fortgeschrieben (frühestes Datum gewinnt).
    public var firstSeenAt: Date

    public init(identifier: String, displayName: String, displayVersion: String?, firstSeenAt: Date) {
        self.identifier = identifier
        self.displayName = displayName
        self.displayVersion = displayVersion
        self.firstSeenAt = firstSeenAt
    }

    public var id: String { identifier }
}

/// Typisierte Rohwerte je Prüfung.
public enum SecurityFacts: Hashable, Sendable, Codable {
    case fileVault(FileVaultStatus)
    case firewall(enabled: Bool, stealthMode: Bool)
    case sip(SIPStatus)
    case gatekeeper(enabled: Bool)
    case xprotect(version: String, installedAt: Date)
    /// Schlüssel, die ausdrücklich `false` sind.
    case automaticUpdates(disabled: Set<SoftwareUpdateKey>)
    case pendingUpdates(updates: [PendingUpdate], lastCheck: Date?)
    case mdmEnrollment(enrolled: Bool, viaDEP: Bool)

    public var kind: SecurityCheckKind {
        switch self {
        case .fileVault: .fileVault
        case .firewall: .firewall
        case .sip: .sip
        case .gatekeeper: .gatekeeper
        case .xprotect: .xprotect
        case .automaticUpdates: .automaticUpdates
        case .pendingUpdates: .pendingUpdates
        case .mdmEnrollment: .mdmEnrollment
        }
    }

    /// Bewertungsrelevanter Unterschied: Zeitstempel (Installationsdatum, `firstSeenAt`, letzte Suche) zählen nicht –
    /// Altern wirkt nur über einen Ampelwechsel.
    func isSignificantlyDifferent(from other: SecurityFacts) -> Bool {
        switch (self, other) {
        case let (.xprotect(version, _), .xprotect(otherVersion, _)):
            version != otherVersion
        case let (.pendingUpdates(updates, _), .pendingUpdates(otherUpdates, _)):
            Set(updates.map(\.identifier)) != Set(otherUpdates.map(\.identifier))
        default:
            self != other
        }
    }
}

/// Ergebnis einer Sicherheitsprüfung im Snapshot.
///
/// Invariante: `facts` gehören immer zu `kind`. `kind` ist unveränderlich; ein unpassendes `facts` bricht beim Setzen
/// ab (Programmierfehler) und wird beim Dekodieren als beschädigte Daten abgelehnt.
public struct SecurityCheck: InventoryRecord, Codable {
    public let kind: SecurityCheckKind
    public var state: SecurityState
    /// Zuletzt gelesene Werte; bei `unknown` die fortgeschriebenen des Vorgängers (oder `nil`).
    public var facts: SecurityFacts? {
        didSet { Self.requireMatching(facts, kind) }
    }
    /// Fehlertext, wenn die Prüfung nicht lesbar war (`state == .unknown`).
    public var detail: String?
    /// Ampel vor dem Ausfall; nur bei `unknown` gesetzt (Carry-Forward).
    public var lastKnownState: SecurityState?

    public init(
        kind: SecurityCheckKind, state: SecurityState, facts: SecurityFacts?, detail: String? = nil,
        lastKnownState: SecurityState? = nil
    ) {
        Self.requireMatching(facts, kind)
        self.kind = kind
        self.state = state
        self.facts = facts
        self.detail = detail
        self.lastKnownState = lastKnownState
    }

    private enum CodingKeys: String, CodingKey {
        case kind, state, facts, detail, lastKnownState
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SecurityCheckKind.self, forKey: .kind)
        let facts = try container.decodeIfPresent(SecurityFacts.self, forKey: .facts)
        guard facts == nil || facts?.kind == kind else {
            throw DecodingError.dataCorruptedError(
                forKey: .facts, in: container, debugDescription: "Fakten passen nicht zur Prüfung \(kind.rawValue)"
            )
        }
        self.init(
            kind: kind,
            state: try container.decode(SecurityState.self, forKey: .state),
            facts: facts,
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
            lastKnownState: try container.decodeIfPresent(SecurityState.self, forKey: .lastKnownState)
        )
    }

    private static func requireMatching(_ facts: SecurityFacts?, _ kind: SecurityCheckKind) {
        precondition(facts == nil || facts?.kind == kind, "Fakten passen nicht zur Prüfung")
    }

    /// Nicht lesbare Prüfung.
    public static func failed(_ kind: SecurityCheckKind, detail: String) -> SecurityCheck {
        SecurityCheck(kind: kind, state: .unknown, facts: nil, detail: detail)
    }

    public var id: String { kind.rawValue }
    public var source: SourceID { .securityPosture }

    /// Ampel für Vergleiche: bei Ausfall die letzte bekannte.
    public var effectiveState: SecurityState? { state == .unknown ? lastKnownState : state }

    /// Signifikant: andere `effectiveState` oder bewertungsrelevant andere Fakten (siehe `SecurityFacts`).
    public func hasSignificantChanges(comparedTo other: SecurityCheck) -> Bool {
        if effectiveState != other.effectiveState { return true }
        guard let facts, let otherFacts = other.facts else { return false }
        return facts.isSignificantlyDifferent(from: otherFacts)
    }

    /// Wie `hasSignificantChanges`, aber eine bisher nie lesbare Prüfung (`effectiveState == nil`), die erstmals einen
    /// Wert liefert, ist Baseline: Ein Vorher gibt es nicht, ein Verlaufseintrag wäre nur „… geändert.“. Das gilt
    /// bewusst auch für einen kritischen ersten Wert – Ampel und Kachel zeigen ihn, und die `NotificationPolicy` meldet
    /// ohne bekannte Vorher-Ampel ohnehin nichts. Gespeichert wird der neue Snapshot trotzdem (`hasSignificantChanges`),
    /// damit der nächste Vergleich vom gelesenen Wert ausgeht.
    public func reportsChange(to other: SecurityCheck) -> Bool {
        effectiveState != nil && hasSignificantChanges(comparedTo: other)
    }
}
