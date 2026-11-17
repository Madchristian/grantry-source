import Foundation

/// Wonach die Ansicht „Verbindungen“ ihre Zeilen in Abschnitte ordnet.
public enum NetworkConnectionGrouping: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Wer einen Socket erreichen kann (`SocketReach`).
    case reach
    /// Wohin die Verbindungen gehen: je Land ein Abschnitt (#630).
    case country

    public var id: Self { self }

    public var title: String {
        switch self {
        case .reach: String(localized: "Erreichbarkeit")
        case .country: String(localized: "Land")
        }
    }
}

/// Ein Abschnitt der Tabelle „Verbindungen“ mit Kopfzeile und Zeilen.
public struct NetworkConnectionSection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let tone: PresentationTone
    /// Befund-Punkt statt der Leiste.
    public let isFinding: Bool
    public let rows: [NetworkSocketRow]

    /// Offene Sockets; eben geschlossene bleiben sichtbar, zählen aber nicht.
    public var openCount: Int { rows.count { !$0.isGone } }

    /// Summe der Raten der offenen Sockets.
    public var rate: TrafficRate { rows.filter { !$0.isGone }.reduce(.zero) { $0 + $1.rate } }

    /// „↓ 1,2 MB/s ↑ 42 KB/s“ für die Kopfzeile; `nil` ohne Verkehr.
    public var rateText: String? { rate.total > 0 ? NetworkConnectionTexts.traffic(rate) : nil }

    /// „Deutschland, 3 Verbindungen, empfängt 1,2 MB/s, sendet 42 KB/s“.
    public func accessibilityLabel(for grouping: NetworkConnectionGrouping) -> String {
        let count = switch (grouping, openCount) {
        case (.country, 1): String(localized: "1 Verbindung")
        case (.country, _): String(localized: "\(openCount) Verbindungen")
        case (.reach, 1): String(localized: "1 Socket")
        case (.reach, _): String(localized: "\(openCount) Sockets")
        }
        var parts = [title, count]
        if rate.total > 0 {
            parts += [String(localized: "empfängt \(TrafficFormat.rate(rate.download))"),
                      String(localized: "sendet \(TrafficFormat.rate(rate.upload))")]
        }
        return parts.joined(separator: ", ")
    }
}

extension NetworkConnectionsPresentation {
    /// Die sichtbaren Zeilen in Abschnitten; leere Abschnitte entfallen.
    ///
    /// Nach Land stehen nur Verbindungen (lauschende und gebundene Sockets haben keine Gegenstelle): erst die Länder –
    /// das mit den meisten offenen Verbindungen zuerst, bei Gleichstand nach Namen –, dann Gegenstellen ohne Eintrag,
    /// das lokale Netz und dieser Mac. Private und lokale Adressen stehen nie unter einem Land.
    public func sections(by grouping: NetworkConnectionGrouping, locale: Locale = .current)
        -> [NetworkConnectionSection] {
        switch grouping {
        case .reach:
            return SocketReach.allCases.compactMap { reach in
                section(id: "reach-\(reach.rawValue)", title: reach.title, tone: reach.tone,
                        isFinding: reach == .network, rows: rows.filter { $0.reach == reach })
            }
        case .country:
            return Self.regionSections(of: rows, locale: locale).map(\.section)
        }
    }

    /// Ziele aller offenen Verbindungen für den Bogenfächer der Karte „Ziele“ – unabhängig von Filter und Suche, in
    /// derselben Reihenfolge wie die Abschnitte nach Land.
    public func destinations(locale: Locale = .current) -> [NetworkDestination] {
        Self.regionSections(of: all.filter { !$0.isGone }, locale: locale).map { region, section in
            let programs = Dictionary(grouping: section.rows, by: \.title).map { title, rows in
                NetworkDestination.Program(title: title, connectionCount: rows.count)
            }.sorted { ($1.connectionCount, $0.title) < ($0.connectionCount, $1.title) }
            return NetworkDestination(
                id: section.id, title: region.title(locale: locale), region: region,
                connectionCount: section.rows.count,
                // Nur eingehend: Jede Verbindung ist TCP auf einem lauschenden Port des Programms.
                isInboundOnly: section.rows.allSatisfy { $0.direction == .inbound }, programs: programs
            )
        }
    }

    /// Verbindungen je Region als Abschnitt: erst die Länder – das mit den meisten offenen Verbindungen zuerst, bei
    /// Gleichstand nach Namen –, dann ohne Eintrag, lokales Netz und dieser Mac.
    private static func regionSections(of rows: [NetworkSocketRow], locale: Locale)
        -> [(region: RemoteRegion, section: NetworkConnectionSection)] {
        let regions = Dictionary(grouping: rows.filter { $0.region != nil }) { $0.region ?? .unknown }
        let sections = regions.map { region, rows in
            (region: region,
             section: NetworkConnectionSection(id: "region-\(region.sortRank)-\(region.title(locale: locale))",
                                               title: region.sectionTitle(locale: locale), tone: .neutral,
                                               isFinding: false, rows: rows))
        }
        return sections.sorted { lhs, rhs in
            if lhs.region.sortRank != rhs.region.sortRank { return lhs.region.sortRank < rhs.region.sortRank }
            if lhs.section.openCount != rhs.section.openCount { return lhs.section.openCount > rhs.section.openCount }
            return lhs.section.title.compare(rhs.section.title, locale: locale) == .orderedAscending
        }
    }

    private func section(id: String, title: String, tone: PresentationTone, isFinding: Bool,
                         rows: [NetworkSocketRow]) -> NetworkConnectionSection? {
        rows.isEmpty ? nil : NetworkConnectionSection(id: id, title: title, tone: tone, isFinding: isFinding,
                                                      rows: rows)
    }
}

/// Ein Ziel der Karte „Ziele“ (#630): ein Land, „Land unbekannt“, das lokale Netz oder dieser Mac mit der Zahl der
/// offenen Verbindungen dorthin und den beteiligten Programmen.
public struct NetworkDestination: Identifiable, Hashable, Sendable, NetworkPickElement {
    public struct Program: Hashable, Sendable {
        public let title: String
        public let connectionCount: Int
    }

    public let id: String
    /// Ländername bzw. „Land unbekannt“, „Lokales Netz“, „Dieser Mac“.
    public let title: String
    public let region: RemoteRegion
    public let connectionCount: Int
    /// Alle Verbindungen dorthin sind eingehend – im Fächer gestrichelt.
    public let isInboundOnly: Bool
    /// Programme mit den meisten Verbindungen zuerst.
    public let programs: [Program]

    public var pickKey: RemoteRegion { region }

    /// Ob das Ziel ein Land ist (für „x Länder“).
    public var isCountry: Bool {
        if case .country = region { true } else { false }
    }

    /// „Deutschland, 3 Verbindungen, nur eingehend: Safari 2, Mail 1“.
    public var accessibilityLabel: String { "\(title), \(accessibilityValue)" }

    /// „3 Verbindungen, nur eingehend: Safari 2, Mail 1“ – Wert zum Namen des Ziels.
    public var accessibilityValue: String {
        let count = connectionCount == 1 ? String(localized: "1 Verbindung")
            : String(localized: "\(connectionCount) Verbindungen")
        let head = ([count] + (isInboundOnly ? [String(localized: "nur eingehend")] : [])).joined(separator: ", ")
        return "\(head): " + programs.map { "\($0.title) \($0.connectionCount)" }.joined(separator: ", ")
    }
}

extension RemoteRegion {
    /// Länder vor Unbekanntem, dem lokalen Netz und diesem Mac.
    var sortRank: Int {
        switch self {
        case .country: 0
        case .unknown: 1
        case .localNetwork: 2
        case .thisMac: 3
        }
    }

    /// Titel des Abschnitts: der Ländername bzw. die Einordnung der Adressen ohne Land.
    func sectionTitle(locale: Locale) -> String {
        switch self {
        case .unknown: String(localized: "Land unbekannt (kein Eintrag)")
        case .localNetwork: String(localized: "Lokales Netz (ohne Land)")
        case .thisMac: String(localized: "Dieser Mac (ohne Land)")
        case .country: title(locale: locale)
        }
    }
}

/// Texte der Ansicht „Verbindungen“, die Tabelle, Kopfzeilen und Detail teilen.
public enum NetworkConnectionTexts {
    /// „PID 4820 · christian“; ohne bekannten Benutzer nur die PID.
    public static func owner(of row: NetworkSocketRow) -> String {
        (["PID \(row.pid)"] + [row.user].compactMap(\.self)).joined(separator: " · ")
    }

    /// „↓ 1,2 MB/s ↑ 42 KB/s“.
    public static func traffic(_ rate: TrafficRate) -> String {
        "↓ \(TrafficFormat.rate(rate.download)) ↑ \(TrafficFormat.rate(rate.upload))"
    }

    /// „Länderdaten: Stand November 2026“; `nil` ohne Tabelle.
    public static func dataDate(_ date: DateComponents?, locale: Locale = .current) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        guard let date, let day = calendar.date(from: date) else { return nil }
        let month = day.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.wide).year())
        return String(localized: "Länderdaten: Stand \(month)")
    }

    /// Was eine Länderangabe aussagt – und was nicht.
    public static var countryLimits: String {
        String(localized: "Das Land gehört zum Adressblock der Gegenstelle, nicht zwingend zum Rechner oder Unternehmen. Bei VPN, Relay und Auslieferungsnetzen ist es das Land des Übergabepunkts. Ein Hinweis, kein Befund. Grantry schlägt dafür nichts im Netz nach; ältere Daten werden ungenauer.")
    }
}
