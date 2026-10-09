import Foundation

/// Nutzerentscheidung, getrennt von den technischen Prüfergebnissen. Die Engine besitzt die Ablage exklusiv.
/// Normale Updates behalten die Akzeptanz; eine andere Identität oder Signaturart verliert sie dauerhaft.
public struct AppRiskAcceptanceStore: Sendable {
    private struct Identity: Codable, Equatable, Sendable {
        let bundleID: String?
        let teamID: String?
        let signingKind: SigningInfo.Kind
        let symlinkTarget: String?

        init(_ app: InstalledApp) {
            bundleID = app.bundleID
            teamID = app.signing.teamID
            signingKind = app.signing.kind
            symlinkTarget = app.symlinkTarget
        }
    }

    private let url: URL?
    private var entries: [String: Identity]?

    /// Ohne URL nur im Speicher, etwa für Tests. Die App übergibt ihren eigenen Ablageort.
    public init(url: URL? = nil) { self.url = url }

    public mutating func setAccepted(_ accepted: Bool, for app: InstalledApp) throws {
        var updated = try loaded()
        updated[app.id] = accepted ? Identity(app) : nil
        try save(updated)
    }

    /// Auch für das letzte bekannte Objekt eines Entfernungs-Events; ändert keine Identität des aktuellen Scans.
    public mutating func isAccepted(_ app: InstalledApp) throws -> Bool {
        try loaded()[app.id] == Identity(app)
    }

    /// Fehlende Apps werden bei Teilscans/Quellfehlern nicht gelöscht. Identitätswechsel dagegen schon,
    /// damit eine Rückkehr zur alten Team-ID die frühere Akzeptanz nicht still wieder aktiviert.
    public mutating func acceptedIDs(in apps: [InstalledApp]) throws -> Set<String> {
        var updated = try loaded()
        var accepted: Set<String> = []
        for app in apps where updated[app.id] != nil {
            if updated[app.id] == Identity(app) {
                accepted.insert(app.id)
            } else {
                updated.removeValue(forKey: app.id)
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
