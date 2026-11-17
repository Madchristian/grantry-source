import Foundation

// Klickfilter der Ansicht „Verbindungen“: Ein Klick auf ein Element einer Karte – ein Ziel im Bogenfächer (#633) oder
// ein Echo im Radar „Erreichbarkeit“ (#640) – filtert die Tabelle daneben auf das, was das Element darstellt. Beide
// wirken zusätzlich zu Segment und Suche und zueinander, gelten bis zum Verlassen der Ansicht und werden nicht
// gespeichert. Verschwindet das Gefilterte aus den Daten, bleibt der Filter stehen und die Tabelle nennt den Grund.

/// Element einer Karte, das sich per Klick als Tabellenfilter wählen lässt: Kennung der Karte und Schlüssel, nach dem
/// die Tabelle filtert.
public protocol NetworkPickElement: Identifiable where ID == String {
    associatedtype PickKey: Hashable & Sendable
    var pickKey: PickKey { get }
}

/// Gemeinsamer Kern der Klickfilter: gewählte Schlüssel in der Reihenfolge der Karte, ohne Doppelte, nie leer.
public struct NetworkPick<Key: Hashable & Sendable>: Hashable, Sendable {
    public let keys: [Key]

    /// `nil` ohne Schlüssel.
    public init?(keys: [Key]) {
        var seen = Set<Key>()
        let keys = keys.filter { seen.insert($0).inserted }
        guard !keys.isEmpty else { return nil }
        self.keys = keys
    }

    /// Klick auf ein Element: wählt die Schlüssel der Elemente mit den Kennungen `ids` (beim Sammel-Element mehrere);
    /// derselbe Klick noch einmal hebt die Wahl auf. Kennungen, die es nicht (mehr) gibt, ändern nichts.
    public static func picking<Element: NetworkPickElement>(_ ids: Set<String>, in elements: [Element],
                                                            current: Self?) -> Self? where Element.PickKey == Key {
        guard let picked = Self(keys: elements.filter { ids.contains($0.id) }.map(\.pickKey)) else { return current }
        return current.map { Set($0.keys) } == Set(picked.keys) ? nil : picked
    }

    /// Kennungen der gewählten Elemente unter `elements` – für die Hervorhebung in der Karte.
    public func ids<Element: NetworkPickElement>(in elements: [Element]) -> Set<String> where Element.PickKey == Key {
        Set(elements.filter { keys.contains($0.pickKey) }.map(\.id))
    }

    /// „Deutschland“, „Deutschland und Land unbekannt“, „Niederlande und 3 weitere“.
    static func title(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return String(localized: "\(names[0]) und \(names[1])")
        default: return String(localized: "\(names[0]) und \(names.count - 1) weitere")
        }
    }
}

/// Ein Klickfilter der Tabelle „Verbindungen“, wie Chip und Leerzustand ihn nennen.
public protocol NetworkPickFilter: Hashable, Sendable {
    /// Art vor dem Titel im Chip, etwa „Ziel“ oder „Programme“.
    var label: String { get }
    func title(locale: Locale) -> String
    /// Hinweis, wenn die Tabelle mit diesem Filter leer bleibt: das Gefilterte ist verschwunden, oder Suche und andere
    /// Filter lassen nichts davon übrig.
    func emptyMessage(isGone: Bool, locale: Locale) -> String
    func includes(_ row: NetworkSocketRow) -> Bool
}

extension NetworkPickFilter {
    /// Ob unter `rows` nichts Offenes mehr zum Filter gehört.
    func isGone(in rows: [NetworkSocketRow]) -> Bool {
        !rows.contains { !$0.isGone && includes($0) }
    }
}

/// Zielfilter aus dem Bogenfächer „Ziele“ (#633): ein Land, „Land unbekannt“, das lokale Netz, dieser Mac oder – über
/// den Sammel-Ast – mehrere davon.
public struct NetworkDestinationFilter: NetworkPickFilter {
    public let pick: NetworkPick<RemoteRegion>

    /// Ziele in der Reihenfolge des Fächers.
    public var regions: [RemoteRegion] { pick.keys }

    public init(pick: NetworkPick<RemoteRegion>) {
        self.pick = pick
    }

    /// `nil` ohne Ziel.
    public init?(regions: [RemoteRegion]) {
        guard let pick = NetworkPick(keys: regions) else { return nil }
        self.init(pick: pick)
    }

    /// Klick auf einen Ast des Fächers (`NetworkPick.picking`).
    public static func picking(_ ids: Set<NetworkDestination.ID>, in destinations: [NetworkDestination],
                               current: Self?) -> Self? {
        NetworkPick.picking(ids, in: destinations, current: current?.pick).map(Self.init(pick:))
    }

    /// Kennungen der gewählten Ziele – für die Hervorhebung im Fächer.
    public func destinationIDs(in destinations: [NetworkDestination]) -> Set<NetworkDestination.ID> {
        pick.ids(in: destinations)
    }

    public func includes(_ row: NetworkSocketRow) -> Bool {
        row.region.map(regions.contains) ?? false
    }

    public var label: String {
        regions.count == 1 ? String(localized: "Ziel") : String(localized: "Ziele")
    }

    public func title(locale: Locale = .current) -> String {
        NetworkPick<RemoteRegion>.title(regions.map { $0.title(locale: locale) })
    }

    public func emptyMessage(isGone: Bool, locale: Locale = .current) -> String {
        let title = title(locale: locale)
        return isGone
            ? String(localized: "Gerade ist keine Verbindung zu „\(title)“ offen. Der Filter bleibt, bis du ihn aufhebst.")
            : String(localized: "Suche und Filter lassen keine Verbindung zu „\(title)“ übrig.")
    }
}

/// Ein Echo des Radars „Erreichbarkeit“: ein lauschendes oder gebundenes Programm auf seinem Port, auf dem Ring seiner
/// Erreichbarkeit (`SocketReach` ohne `.connected`).
public struct NetworkReachEcho: Identifiable, Hashable, Sendable, NetworkPickElement {
    /// Wofür das Echo steht: Programm, Port und Ring.
    public struct Key: Hashable, Sendable {
        public let title: String
        public let port: UInt16?
        public let reach: SocketReach

        /// Gehört die Zeile zum Echo: lauschende und gebundene Sockets des Programms auf dem Port und Ring, dazu die
        /// Verbindungen, die auf diesem Port ankommen.
        func includes(_ row: NetworkSocketRow) -> Bool {
            guard row.title == title, row.socket.local.port == port else { return false }
            return row.kind == .connected ? port != nil : row.reach == reach
        }
    }

    public let key: Key

    init(row: NetworkSocketRow) {
        key = Key(title: row.title, port: row.socket.local.port, reach: row.reach)
    }

    public var id: String { "\(key.title)|\(key.port.map(String.init) ?? "")|\(key.reach.rawValue)" }
    /// „node :3000“.
    public var label: String { Self.label(of: key) }
    public var reach: SocketReach { key.reach }
    public var pickKey: Key { key }
}

extension NetworkConnectionsPresentation {
    /// Lauschende und gebundene Programme je Port und Ring für das Radar „Erreichbarkeit“ – unabhängig von Filter und
    /// Suche, ohne Geschlossene; IPv4 und IPv6 auf demselben Port sind ein Echo.
    public func reachEchoes() -> [NetworkReachEcho] {
        var seen = Set<NetworkReachEcho.Key>()
        return all.filter { !$0.isGone && $0.kind != .connected }
            .map(NetworkReachEcho.init(row:))
            .filter { seen.insert($0.key).inserted }
    }
}

/// Programmfilter aus dem Radar „Erreichbarkeit“ (#640): ein Programm auf seinem Port oder – über das Sammel-Echo
/// „+n“ – mehrere.
public struct NetworkEchoFilter: NetworkPickFilter {
    public let pick: NetworkPick<NetworkReachEcho.Key>

    public init(pick: NetworkPick<NetworkReachEcho.Key>) {
        self.pick = pick
    }

    /// `nil` ohne Echo.
    public init?(echoes: [NetworkReachEcho]) {
        guard let pick = NetworkPick(keys: echoes.map(\.key)) else { return nil }
        self.init(pick: pick)
    }

    /// Klick auf ein Echo des Radars (`NetworkPick.picking`).
    public static func picking(_ ids: Set<NetworkReachEcho.ID>, in echoes: [NetworkReachEcho],
                               current: Self?) -> Self? {
        NetworkPick.picking(ids, in: echoes, current: current?.pick).map(Self.init(pick:))
    }

    /// Kennungen der gewählten Echos – für die Hervorhebung im Radar.
    public func echoIDs(in echoes: [NetworkReachEcho]) -> Set<NetworkReachEcho.ID> {
        pick.ids(in: echoes)
    }

    public func includes(_ row: NetworkSocketRow) -> Bool {
        pick.keys.contains { $0.includes(row) }
    }

    public var label: String {
        pick.keys.count == 1 ? String(localized: "Programm") : String(localized: "Programme")
    }

    public func title(locale: Locale = .current) -> String {
        NetworkPick<NetworkReachEcho.Key>.title(pick.keys.map { NetworkReachEcho.label(of: $0) })
    }

    public func emptyMessage(isGone: Bool, locale: Locale = .current) -> String {
        let title = title(locale: locale)
        return isGone
            ? String(localized: "Gerade ist „\(title)“ nicht offen. Der Filter bleibt, bis du ihn aufhebst.")
            : String(localized: "Suche und Filter lassen von „\(title)“ nichts übrig.")
    }
}

extension NetworkReachEcho {
    /// „node :3000“; ohne Port nur der Name.
    static func label(of key: Key) -> String {
        key.port.map { "\(key.title) :\($0)" } ?? key.title
    }
}

/// Art eines Klickfilters, etwa um ihn einzeln aufzuheben.
public enum NetworkPickKind: Hashable, Sendable {
    case destination, echo

    /// Was ein Klick auf den Chip bewirkt, als Tooltip und VoiceOver-Hinweis.
    public var removeHint: String {
        switch self {
        case .destination: String(localized: "Hebt den Zielfilter auf")
        case .echo: String(localized: "Hebt den Programmfilter auf")
        }
    }
}

/// Die Klickfilter der Ansicht „Verbindungen“ zusammen; nicht gespeichert.
public struct NetworkPickFilters: Hashable, Sendable {
    public var destination: NetworkDestinationFilter?
    public var echo: NetworkEchoFilter?

    public init(destination: NetworkDestinationFilter? = nil, echo: NetworkEchoFilter? = nil) {
        self.destination = destination
        self.echo = echo
    }

    public var isEmpty: Bool { destination == nil && echo == nil }

    /// Die gesetzten Filter, der Programmfilter vor dem Zielfilter – für Chips und Leerzustand.
    public var active: [(kind: NetworkPickKind, filter: any NetworkPickFilter)] {
        (echo.map { [(.echo, $0)] } ?? []) + (destination.map { [(.destination, $0)] } ?? [])
    }

    public mutating func clear(_ kind: NetworkPickKind) {
        switch kind {
        case .destination: destination = nil
        case .echo: echo = nil
        }
    }
}

/// Leerzustand der Tabelle mit Klickfilter: welcher Filter sie leert und warum.
public struct NetworkPickNotice: Hashable, Sendable {
    public let kind: NetworkPickKind
    public let message: String

    /// „Keine Verbindungen zu diesem Ziel“ bzw. „Keine Sockets dieses Programms“.
    public var title: String {
        switch kind {
        case .destination: String(localized: "Keine Verbindungen zu diesem Ziel")
        case .echo: String(localized: "Keine Sockets dieses Programms")
        }
    }

    /// „Zielfilter aufheben“ bzw. „Programmfilter aufheben“.
    public var resetTitle: String {
        switch kind {
        case .destination: String(localized: "Zielfilter aufheben")
        case .echo: String(localized: "Programmfilter aufheben")
        }
    }

    /// SF Symbol des Leerzustands.
    public var symbol: String {
        switch kind {
        case .destination: "globe"
        case .echo: "dot.radiowaves.left.and.right"
        }
    }
}
