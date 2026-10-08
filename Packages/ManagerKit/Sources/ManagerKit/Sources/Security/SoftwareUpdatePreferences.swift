import Foundation

/// Gelesene Werte aus `SecurityTools.softwareUpdatePreferences`.
struct SoftwareUpdatePreferences: Equatable, Sendable {
    struct RecommendedUpdate: Equatable, Sendable {
        let identifier: String
        let displayName: String
        let displayVersion: String?
        /// `FirstOfferDateDictionary[Product Key]` (ersatzweise `[Identifier]`); fehlt bei Nicht-MSU-Updates.
        let firstOfferedAt: Date?
    }

    /// Ausdrücklich auf `false` gesetzte Schlüssel; fehlende gelten als „an“ (macOS-Standard).
    let disabledKeys: Set<SoftwareUpdateKey>
    let recommendedUpdates: [RecommendedUpdate]
    /// Letzte erfolgreiche Suche: der neueste der Stempel `successKeys`; `nil`, wenn keiner ein Datum ist.
    let lastSuccessfulCheck: Date?

    /// Erfolgsstempel der Update-Suche. macOS pflegt sie je nach Weg getrennt – `softwareupdate --list` als Nutzer
    /// aktualisierte (2026-10) nur `LastSuccessfulMSUScanDate`, die Suche im Hintergrund `LastBackgroundSuccessfulDate`.
    static let successKeys = [
        "LastSuccessfulDate", "LastFullSuccessfulDate", "LastBackgroundSuccessfulDate", "LastSuccessfulMSUScanDate",
    ]

    init(data: Data, path: String = SecurityTools.softwareUpdatePreferences) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SecurityParseError.unreadablePreferences(path: path)
        }
        disabledKeys = Set(SoftwareUpdateKey.allCases.filter { (plist[$0.rawValue] as? Bool) == false })
        // Einzeln gelesen: Ein kaputter Eintrag verwirft nicht die übrigen Angebotsdaten.
        let offers = (plist["FirstOfferDateDictionary"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Date }
        recommendedUpdates = (plist["RecommendedUpdates"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let identifier = entry["Identifier"] as? String else { return nil }
            let productKey = entry["Product Key"] as? String
            return RecommendedUpdate(
                identifier: identifier,
                displayName: entry["Display Name"] as? String ?? identifier,
                displayVersion: entry["Display Version"] as? String,
                firstOfferedAt: productKey.flatMap { offers[$0] } ?? offers[identifier]
            )
        }
        lastSuccessfulCheck = Self.successKeys.compactMap { plist[$0] as? Date }.max()
    }

    /// Ausstehende Updates; ohne Angebotsdatum beginnt „ausstehend“ bei `firstSeenFallback` (über Scans fortgeschrieben:
    /// `Snapshot.carryingForwardSecurityState`).
    func pendingUpdates(firstSeenFallback: Date) -> [PendingUpdate] {
        recommendedUpdates.map { update in
            PendingUpdate(
                identifier: update.identifier, displayName: update.displayName, displayVersion: update.displayVersion,
                firstSeenAt: update.firstOfferedAt ?? firstSeenFallback
            )
        }
    }
}
