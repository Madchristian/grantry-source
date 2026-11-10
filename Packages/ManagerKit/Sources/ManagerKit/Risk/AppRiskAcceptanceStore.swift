import Foundation

/// Ein Eintrag, dessen Befunde der Nutzer akzeptieren kann (`RiskAcceptanceStore`).
public protocol RiskAcceptable: Sendable {
    /// Was gleich bleiben muss, damit eine Akzeptanz weiter gilt; ein normales Update ändert es nicht.
    associatedtype AcceptanceIdentity: Codable, Equatable, Sendable

    var id: String { get }
    /// `nil`, wenn die Identität in diesem Scan nicht belegt ist: Die Akzeptanz gilt dann nicht, bleibt aber erhalten.
    var acceptanceIdentity: AcceptanceIdentity? { get }
}

public enum RiskAcceptanceError: Error, Equatable {
    /// Die Identität des Eintrags ist nicht belegt (`RiskAcceptable.acceptanceIdentity`).
    case identityUnknown
}

/// Nutzerentscheidung, getrennt von den technischen Prüfergebnissen. Die Engine besitzt die Ablage exklusiv.
/// Normale Updates behalten die Akzeptanz; eine andere Identität verliert sie dauerhaft.
public struct RiskAcceptanceStore<Record: RiskAcceptable>: Sendable {
    private typealias Identity = Record.AcceptanceIdentity

    private let url: URL?
    private var entries: [String: Identity]?

    /// Ohne URL nur im Speicher, etwa für Tests. Die App übergibt ihren eigenen Ablageort.
    public init(url: URL? = nil) { self.url = url }

    public mutating func setAccepted(_ accepted: Bool, for record: Record) throws {
        var updated = try loaded()
        if accepted {
            guard let identity = record.acceptanceIdentity else { throw RiskAcceptanceError.identityUnknown }
            updated[record.id] = identity
        } else {
            updated[record.id] = nil
        }
        try save(updated)
    }

    /// Auch für das letzte bekannte Objekt eines Entfernungs-Events; ändert keine Identität des aktuellen Scans.
    public mutating func isAccepted(_ record: Record) throws -> Bool {
        guard let identity = record.acceptanceIdentity else { return false }
        return try loaded()[record.id] == identity
    }

    /// Fehlende Einträge werden bei Teilscans/Quellfehlern nicht gelöscht, solche ohne belegte Identität ebenso wenig.
    /// Identitätswechsel dagegen schon, damit eine Rückkehr zur alten Identität die frühere Akzeptanz nicht still wieder
    /// aktiviert.
    public mutating func acceptedIDs(in records: [Record]) throws -> Set<String> {
        var updated = try loaded()
        var accepted: Set<String> = []
        for record in records where updated[record.id] != nil {
            guard let identity = record.acceptanceIdentity else { continue }
            if updated[record.id] == identity {
                accepted.insert(record.id)
            } else {
                updated.removeValue(forKey: record.id)
            }
        }
        if updated != entries { try save(updated) }
        return accepted
    }

    private mutating func loaded() throws -> [String: Identity] {
        if let entries { return entries }
        let loaded: [String: Identity]
        if let url {
            do {
                loaded = try JSONDecoder().decode([String: Identity].self, from: Data(contentsOf: url))
            } catch CocoaError.fileReadNoSuchFile {
                loaded = [:]
            }
        } else {
            loaded = [:]
        }
        entries = loaded
        return loaded
    }

    /// Erst nach erfolgreichem atomarem Schreiben gilt die Entscheidung auch im Speicher.
    private mutating func save(_ updated: [String: Identity]) throws {
        if let url {
            let directory = try PrivateDirectory(at: url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(updated)
            try PrivateFile.writeAtomically(Array(data), named: url.lastPathComponent, in: directory.bound)
        }
        entries = updated
    }
}

/// Akzeptierte App-Risiken: Eine andere Bundle-ID, Team-ID, Signaturart oder ein anderes Symlink-Ziel beendet die
/// Akzeptanz.
public typealias AppRiskAcceptanceStore = RiskAcceptanceStore<InstalledApp>

extension InstalledApp: RiskAcceptable {
    /// Format der Ablage `AppRiskAcceptances.json`; Namen der Felder nicht ändern.
    public struct AcceptanceIdentity: Codable, Equatable, Sendable {
        let bundleID: String?
        let teamID: String?
        let signingKind: SigningInfo.Kind
        let symlinkTarget: String?
    }

    public var acceptanceIdentity: AcceptanceIdentity? {
        AcceptanceIdentity(bundleID: bundleID, teamID: signing.teamID, signingKind: signing.kind, symlinkTarget: symlinkTarget)
    }
}

/// Akzeptierte Befunde von Erweiterungen (TM-13.4): Ein Wechsel des Teams oder der Signaturart beendet die Akzeptanz.
/// Bei Systemerweiterungen gehört das Team schon zur `id` – eine Erweiterung eines anderen Teams ist ein anderer Eintrag.
public typealias ExtensionRiskAcceptanceStore = RiskAcceptanceStore<ExtensionRecord>

extension ExtensionRecord: RiskAcceptable {
    public struct AcceptanceIdentity: Codable, Equatable, Sendable {
        let bundleID: String
        let teamID: String?
        /// `nil` für Systemerweiterungen (macOS prüft sie bei der Aktivierung) und Kernel-Erweiterungen ohne Pfad.
        let signingKind: SigningInfo.Kind?
    }

    /// `nil` nach einer abgelaufenen Signaturprüfung: Team und Signaturart sind dann nicht belegt.
    public var acceptanceIdentity: AcceptanceIdentity? {
        guard isSigningConclusive else { return nil }
        return AcceptanceIdentity(bundleID: bundleID, teamID: teamID, signingKind: signing?.kind)
    }
}
