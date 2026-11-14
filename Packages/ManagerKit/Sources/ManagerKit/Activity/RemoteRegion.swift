import Foundation
import os

/// Wohin eine Gegenstelle gehört (#630): dieser Mac, das lokale Netz, das Land ihres Adressblocks oder unbekannt.
/// Private und lokale Adressen bekommen nie ein Land.
public enum RemoteRegion: Hashable, Sendable {
    /// Loopback.
    case thisMac
    /// Private, Link-Local-, CGNAT- und Sonderadressen.
    case localNetwork
    /// Öffentliche Adresse mit Eintrag: ISO-3166-Code des Adressblocks.
    case country(String)
    /// Öffentliche Adresse ohne Eintrag in der Tabelle, oder keine lesbare Adresse.
    case unknown

    /// „Deutschland“ über die Systemlokalisierung (ohne eigene Übersetzungstabelle); ein Code, den das System nicht
    /// kennt, steht für sich.
    public func title(locale: Locale = .current) -> String {
        switch self {
        case .thisMac: String(localized: "Dieser Mac")
        case .localNetwork: String(localized: "Lokales Netz")
        case .country(let code): locale.localizedString(forRegionCode: code) ?? code
        case .unknown: String(localized: "Land unbekannt")
        }
    }
}

/// Ordnet Gegenstellen ihre `RemoteRegion` zu – rein lokal, ohne Netzverkehr und ohne DNS. Ergebnisse je Adresse
/// bleiben im Zwischenspeicher, damit jede Messung nur neue Gegenstellen nachschlägt.
public final class RemoteRegionResolver: Sendable {
    /// Stand der Länderdaten; `nil` ohne Tabelle.
    public let dataDate: DateComponents?

    private let countryCode: @Sendable (String) -> String?
    private let cache = OSAllocatedUnfairLock(initialState: [String: RemoteRegion]())
    /// So viele Adressen merkt sich der Zwischenspeicher, bevor er neu beginnt.
    static let cacheLimit = 2048

    /// Ohne Tabelle: öffentliche Adressen bleiben unbekannt.
    public static let unavailable = RemoteRegionResolver(dataDate: nil) { _ in nil }

    /// - Parameter countryCode: Ländercode zu einer öffentlichen Adresse, `nil` ohne Eintrag.
    public init(dataDate: DateComponents?, countryCode: @escaping @Sendable (String) -> String?) {
        self.dataDate = dataDate
        self.countryCode = countryCode
    }

    public convenience init(table: CountryTable) {
        self.init(dataDate: table.dataDate, countryCode: table.countryCode(for:))
    }

    /// Lädt die Tabelle aus den Ressourcen von `bundle`; fehlt sie oder ist sie unbrauchbar, bleibt alles Öffentliche
    /// unbekannt statt falsch zugeordnet.
    public convenience init(bundle: Bundle) {
        let url = bundle.url(forResource: CountryTable.resourceName, withExtension: CountryTable.resourceExtension)
        if let table = url.flatMap({ try? CountryTable(contentsOf: $0) }) {
            self.init(table: table)
        } else {
            self.init(dataDate: nil) { _ in nil }
        }
    }

    public func region(of address: String) -> RemoteRegion {
        cache.withLock { cache in
            if let known = cache[address] { return known }
            let region = resolve(address)
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[address] = region
            return region
        }
    }

    private func resolve(_ address: String) -> RemoteRegion {
        guard let numeric = NumericIPAddress(address) else { return .unknown }
        guard IPAddressScope.isPublic(numeric) else {
            return IPAddressScope.location(of: address) == .thisMac ? .thisMac : .localNetwork
        }
        return countryCode(address).map(RemoteRegion.country) ?? .unknown
    }
}
