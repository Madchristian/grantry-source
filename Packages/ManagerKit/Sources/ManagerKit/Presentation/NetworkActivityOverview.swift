import Foundation

/// Kennzahlen der Ansicht Netzwerk › Aktivität im Lagebild (#366) für den ganzen Mac – unabhängig von Filter und Suche
/// der Tabelle – und das Urteil der Zustandszeile.
public struct NetworkActivityOverview: Hashable, Sendable {
    public let rate: TrafficRate
    /// Übertragen seit Beginn der Messung, alle Prozesse.
    public let transferred: ByteTotals
    /// Prozesse, die gerade senden oder empfangen.
    public let activePrograms: Int
    public let openConnections: Int
    /// Offene Verbindungen, die eben hinzugekommen sind.
    public let newConnections: Int
    /// Verschiedene Gegenstellen der offenen Verbindungen.
    public let remoteHosts: Int

    public init(report: TrafficReport) {
        let open = report.processes.flatMap(\.connections).filter { !$0.isGone }
        rate = report.total
        transferred = report.processes.reduce(.zero) { total, process in
            ByteTotals(received: total.received + process.transferred.received,
                       sent: total.sent + process.transferred.sent)
        }
        activePrograms = report.processes.count { !$0.isGone && $0.rate.total > 0 }
        openConnections = open.count
        newConnections = open.count(where: \.isNew)
        remoteHosts = Set(open.compactMap(\.connection.remote.address)).count
    }

    /// Wie viele Programme gerade im Netz aktiv sind; Netzwerkaktivität allein ist kein Befund.
    public var verdict: SystemVerdict {
        let title = switch activePrograms {
        case 0: String(localized: "Gerade keine Netzwerkaktivität")
        case 1: String(localized: "1 Programm im Netz aktiv")
        default: String(localized: "\(activePrograms) Programme im Netz aktiv")
        }
        let items: [SystemVerdict.Item] = switch newConnections {
        case 0: []
        case 1: [SystemVerdict.Item(text: String(localized: "1 neue Verbindung"), tone: .neutral)]
        default: [SystemVerdict.Item(text: String(localized: "\(newConnections) neue Verbindungen"), tone: .neutral)]
        }
        let connections = openConnections == 1
            ? String(localized: "1 Verbindung") : String(localized: "\(openConnections) Verbindungen")
        let hosts = remoteHosts == 1
            ? String(localized: "1 Gegenstelle") : String(localized: "\(remoteHosts) Gegenstellen")
        return SystemVerdict(level: .calm, title: title, reason: "", items: items, processFindings: [],
                             facts: "\(connections) · \(hosts) · \(String(localized: "live über nettop"))")
    }
}

/// Summen und Spitzen der sichtbaren Prozesszeilen für die Spaltenköpfe und die Hitze der Raten.
public struct NetworkActivityColumnSummary: Hashable, Sendable {
    public let rate: TrafficRate
    public let bytes: UInt64
    public let connections: Int
    /// Höchste Rate je Richtung unter den Prozesszeilen; Maßstab der Hitze.
    public let peak: TrafficRate

    public init(rows: [NetworkActivityRow]) {
        rate = rows.reduce(.zero) { $0 + TrafficRate(download: $1.downloadRate, upload: $1.uploadRate) }
        bytes = rows.reduce(0) { $0 + $1.totalBytes }
        connections = rows.reduce(0) { $0 + $1.connectionCount }
        peak = TrafficRate(download: rows.map(\.downloadRate).max() ?? 0, upload: rows.map(\.uploadRate).max() ?? 0)
    }

    /// Anteil von `value` an der Spitze der Richtung; `nil` ohne Verkehr in dieser Richtung.
    public func heat(_ value: Double, of direction: KeyPath<TrafficRate, Double>) -> Double? {
        let peak = peak[keyPath: direction]
        return peak > 0 ? min(value / peak, 1) : nil
    }
}

/// Sortierbare Spalten der Aktivitätstabelle: Name aufsteigend, Werte zuerst absteigend; ein zweiter Klick kehrt um.
public enum NetworkActivityColumn: String, CaseIterable, Sendable {
    case name, download, upload, total, connections

    /// Spalte, nach der `sortOrder` zuerst sortiert; `nil` für die Standardsortierung nach Gesamtrate.
    public init?(sortedBy sortOrder: [KeyPathComparator<NetworkActivityRow>]) {
        guard let keyPath = sortOrder.first?.keyPath,
              let column = Self.allCases.first(where: { $0.keyPath == keyPath }) else { return nil }
        self = column
    }

    public var defaultOrder: SortOrder { self == .name ? .forward : .reverse }

    public func comparator(order: SortOrder) -> KeyPathComparator<NetworkActivityRow> {
        switch self {
        case .name: KeyPathComparator(\.title, comparator: .localizedStandard, order: order)
        case .download: KeyPathComparator(\.downloadRate, order: order)
        case .upload: KeyPathComparator(\.uploadRate, order: order)
        case .total: KeyPathComparator(\.totalBytes, order: order)
        case .connections: KeyPathComparator(\.connectionCount, order: order)
        }
    }

    /// Sortierung nach einem Klick auf `column`: dieselbe Spalte kehrt die Richtung um, eine andere beginnt mit ihrer
    /// Standardrichtung.
    public static func sortOrder(selecting column: NetworkActivityColumn,
                                 current: [KeyPathComparator<NetworkActivityRow>])
        -> [KeyPathComparator<NetworkActivityRow>] {
        guard Self(sortedBy: current) == column, let order = current.first?.order else {
            return [column.comparator(order: column.defaultOrder)]
        }
        return [column.comparator(order: order == .forward ? .reverse : .forward)]
    }

    private var keyPath: PartialKeyPath<NetworkActivityRow> {
        switch self {
        case .name: \.title
        case .download: \.downloadRate
        case .upload: \.uploadRate
        case .total: \.totalBytes
        case .connections: \.connectionCount
        }
    }
}
