import Foundation

/// Freigabedienst, über den andere Geräte auf den Mac zugreifen (Systemeinstellungen › Allgemein › Teilen, #409).
/// Erkannt an einem von außen erreichbaren TCP-Lauscher auf dem bekannten Port – bei den Diensten von macOS hält
/// launchd den Socket und startet den Dienst erst bei einer Verbindung. Ein anderes Programm auf demselben Port zählt
/// ebenso: Es nimmt dieselbe Art Verbindung an.
/// Die Reihenfolge der Fälle ist die Anzeigereihenfolge.
public enum SharingService: String, Hashable, Sendable, Codable, CaseIterable {
    case screenSharing, fileSharing, remoteLogin

    /// TCP-Ports des Dienstes: VNC (auch entfernte Verwaltung), SMB und AFP, SSH.
    public var ports: [UInt16] {
        switch self {
        case .screenSharing: [5900]
        case .fileSharing: [445, 548]
        case .remoteLogin: [22]
        }
    }

    /// Dienste mit mindestens einem von außen erreichbaren Lauscher; ohne Bewertung von Programm und Signatur.
    public static func active(in listeners: [NetworkListener]) -> Set<SharingService> {
        let ports = Set(listeners.lazy.filter { $0.transport == .tcp && $0.reachability.isExposed }.compactMap(\.port))
        return Set(allCases.filter { !ports.isDisjoint(with: $0.ports) })
    }
}
