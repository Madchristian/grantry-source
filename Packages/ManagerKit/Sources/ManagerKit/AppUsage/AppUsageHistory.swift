import Foundation

/// Kennzahl des App-Verlaufs.
public enum AppUsageMetric: String, Hashable, Sendable, CaseIterable, Identifiable {
    case cpu, energy, network, disk

    public var id: Self { self }
}

/// Verbrauch einer App oder eines Programms in einem Zeitraum. CPU-Zeit in Sekunden (ein voll ausgelasteter Kern eine
/// Sekunde lang = 1 s), Energie in Joule, Netz (Empfangen + Senden) und Datenträger (Lesen + Schreiben) in Byte.
/// Energie und Netz sind `nil`, solange sie nicht gemessen wurden (ohne Energiequelle, etwa auf Intel, bzw. ohne
/// nettop) – das ist kein Verbrauch von 0.
public struct AppUsageTotals: Hashable, Sendable {
    public var cpuSeconds: Double
    public var energyJoules: Double?
    public var networkBytes: Double?
    public var diskBytes: Double

    /// Kein Verbrauch, Energie und Netz nicht gemessen; neutral beim Addieren.
    public static let empty = AppUsageTotals(cpuSeconds: 0, energyJoules: nil, networkBytes: nil, diskBytes: 0)

    public init(cpuSeconds: Double, energyJoules: Double?, networkBytes: Double?, diskBytes: Double) {
        self.cpuSeconds = cpuSeconds
        self.energyJoules = energyJoules
        self.networkBytes = networkBytes
        self.diskBytes = diskBytes
    }

    /// `nil`, wenn die Kennzahl nicht gemessen wurde.
    public subscript(metric: AppUsageMetric) -> Double? {
        switch metric {
        case .cpu: cpuSeconds
        case .energy: energyJoules
        case .network: networkBytes
        case .disk: diskBytes
        }
    }

    /// Summe; Energie und Netz zählen das Gemessene und bleiben nur `nil`, wenn beide Seiten nicht gemessen sind.
    public static func + (lhs: AppUsageTotals, rhs: AppUsageTotals) -> AppUsageTotals {
        AppUsageTotals(cpuSeconds: lhs.cpuSeconds + rhs.cpuSeconds,
                       energyJoules: sum(lhs.energyJoules, rhs.energyJoules),
                       networkBytes: sum(lhs.networkBytes, rhs.networkBytes), diskBytes: lhs.diskBytes + rhs.diskBytes)
    }

    public static func += (lhs: inout AppUsageTotals, rhs: AppUsageTotals) { lhs = lhs + rhs }

    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs else { return rhs }
        return lhs + (rhs ?? 0)
    }

    /// Nichts verbraucht (nicht Gemessenes zählt nicht).
    var isUnused: Bool {
        cpuSeconds == 0 && (energyJoules ?? 0) == 0 && (networkBytes ?? 0) == 0 && diskBytes == 0
    }

    /// Kleinstverbrauch einer abgeschlossenen Stunde: unter 1 s CPU, 1 J und 1 MB Netz und Datenträger.
    var isNegligible: Bool { cpuSeconds < 1 && (energyJoules ?? 0) < 1 && (networkBytes ?? 0) + diskBytes < 1_000_000 }
}

extension AppUsageTotals: Codable {
    /// Kompakt als `[CPU, Energie, Netz, Datenträger]`, CPU und Energie auf 0,1, Bytes auf ganze Zahlen gerundet;
    /// nicht Gemessenes als `null`.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        func optional() throws -> Double? { try container.decodeNil() ? nil : container.decode(Double.self) }
        self.init(cpuSeconds: try container.decode(Double.self), energyJoules: try optional(),
                  networkBytes: try optional(), diskBytes: try container.decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode((cpuSeconds * 10).rounded() / 10)
        try container.encode(energyJoules.map { ($0 * 10).rounded() / 10 })
        try container.encode(networkBytes.map { $0.rounded() })
        try container.encode(diskBytes.rounded())
    }
}

/// Wofür der Verlauf zählt: eine App (Bundle-ID, sonst Name) oder ein eigenes Programm ohne App (Programmname ohne
/// Argumente). Prozesse anderer Benutzer zeichnet der Verlauf nicht auf (Spec §6: keine Namen fremder Benutzerprozesse).
public struct AppUsageSubject: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case app, process
    }

    public let kind: Kind
    public let bundleID: String?
    public let name: String
    /// Zuletzt gesehener Ort des Bundles, nur für das Symbol.
    public let bundlePath: String?

    public init(kind: Kind, bundleID: String?, name: String, bundlePath: String?) {
        self.kind = kind
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
    }

    public var id: String { "\(kind.rawValue):\(bundleID ?? name)" }
}

/// Eine Stunde des App-Verlaufs: Verbrauch je Gegenstand (`AppUsageSubject.id`) und wie lange gemessen wurde.
public struct AppUsageHour: Hashable, Sendable, Codable {
    /// Beginn der Stunde (volle Stunde seit 1970, unabhängig von der Zeitzone).
    public let start: Date
    /// Gemessene Sekunden – der Verlauf enthält nur Zeiten, in denen Grantry gemessen hat.
    public var measuredSeconds: Double
    /// Davon mit Netzmessung (nettop lief).
    public var networkSeconds: Double
    public var usage: [String: AppUsageTotals]

    /// Summe der Kennzahl über alle Gegenstände; `nil`, wenn sie in dieser Stunde nicht gemessen wurde: ohne Messung,
    /// Netz ohne nettop, Energie bei keinem Gegenstand.
    func total(_ metric: AppUsageMetric) -> Double? {
        guard measuredSeconds > 0, metric != .network || networkSeconds > 0 else { return nil }
        return usage.values.reduce(AppUsageTotals.empty, +)[metric]
    }
}

/// App-Verlauf des Task-Managers (Spec 2026-11-06 §6 Stufe 2): Verbrauch je App und Stunde, 30 Tage. Rein und ohne
/// Uhr; Laden und Speichern übernimmt `AppUsageStore`, das Aufzeichnen `AppUsageModel`.
public struct AppUsageHistory: Hashable, Sendable, Codable {
    public static let retention: TimeInterval = 30 * 86_400
    /// Version 2 speichert nicht Gemessenes als `null`; Version 1 schrieb dafür 0 (`migratedFromVersion1()`).
    static let currentVersion = 2
    /// Stand der Netzmessung, seit die Messzeitpunkte aus nettops Takt stammen (Bewertung 2026.11.7-1188, Mangel 2).
    static let currentNetworkRevision = 2

    /// Aufsteigend nach Beginn.
    public private(set) var hours: [AppUsageHour] = []
    public private(set) var subjects: [String: AppUsageSubject] = [:]
    private var version = Self.currentVersion
    /// Stand der Netzmessung der gespeicherten Netzwerte. Fehlt er, stammen sie aus überhöhten Raten
    /// (`withoutNetworkBeforeTimestampFix()`). Ein zusätzlicher Schlüssel statt einer neuen Version: Ältere
    /// Grantry-Versionen übergehen ihn und lesen die Datei weiter; schreiben sie sie neu, fehlt er wieder, und die
    /// Netzwerte gelten erneut als nicht gemessen.
    private var networkRevision: Int? = Self.currentNetworkRevision

    public init() {}

    public var isEmpty: Bool { hours.isEmpty }

    /// Trägt einen gemessenen Abschnitt in die Stunde seines Endes ein.
    public mutating func add(_ sample: AppUsageSample) {
        let start = Self.hourStart(of: sample.end)
        let index: Int
        if let existing = hours.lastIndex(where: { $0.start == start }) {
            index = existing
        } else {
            index = hours.firstIndex { $0.start > start } ?? hours.endIndex
            hours.insert(AppUsageHour(start: start, measuredSeconds: 0, networkSeconds: 0, usage: [:]), at: index)
        }
        hours[index].measuredSeconds += sample.seconds
        if sample.measuresNetwork { hours[index].networkSeconds += sample.seconds }
        for (subject, totals) in sample.usage {
            subjects[subject.id] = subject
            hours[index].usage[subject.id, default: .empty] += totals
        }
    }

    /// Entfernt Stunden älter als `retention`, in abgeschlossenen Stunden Kleinstverbraucher und danach nicht mehr
    /// genannte Gegenstände. Die gemessene Zeit einer Stunde bleibt.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let current = Self.hourStart(of: now)
        hours = hours.filter { $0.start >= cutoff }.map { hour in
            guard hour.start < current else { return hour }
            var finished = hour
            finished.usage = hour.usage.filter { !$0.value.isNegligible }
            return finished
        }
        let named = Set(hours.flatMap(\.usage.keys))
        subjects = subjects.filter { named.contains($0.key) }
    }

    public static func hourStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    /// Datei einer unbekannten Version (etwa von einer neueren Grantry).
    public struct UnknownVersion: LocalizedError, Equatable, Sendable {
        public let version: Int

        public var errorDescription: String? { "Unbekannte Version \(version) der Verlaufsdatei" }
    }

    /// Version 1 wird übernommen (`migratedFromVersion1()`), Netzwerte von vor der Korrektur der Messzeitpunkte gelten
    /// als nicht gemessen (`withoutNetworkBeforeTimestampFix()`).
    /// - Throws: `UnknownVersion` für eine andere Version, sonst Fehler des `JSONDecoder`.
    static func decode(_ data: Data) throws -> AppUsageHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var history = try decoder.decode(AppUsageHistory.self, from: data)
        switch history.version {
        case currentVersion: break
        case 1: history = history.migratedFromVersion1()
        default: throw UnknownVersion(version: history.version)
        }
        return history.networkRevision == currentNetworkRevision ? history : history.withoutNetworkBeforeTimestampFix()
    }

    /// Version 1 speicherte nicht Gemessenes als 0 und kann es von gemessener 0 nicht unterscheiden; im Zweifel gilt es
    /// als nicht gemessen: Netz in Stunden ohne nettop, Energie 0.
    private func migratedFromVersion1() -> AppUsageHistory {
        var migrated = self
        migrated.version = Self.currentVersion
        migrated.hours = hours.map { hour in
            var hour = hour
            hour.usage = hour.usage.mapValues { totals in
                var totals = totals
                if hour.networkSeconds == 0 { totals.networkBytes = nil }
                if totals.energyJoules == 0 { totals.energyJoules = nil }
                return totals
            }
            return hour
        }
        return migrated
    }

    /// Bis zur Korrektur der Messzeitpunkte (nettop gibt seine Ausgabe gepuffert ab, `NettopSchedule`) waren die
    /// Netzraten und damit alle gespeicherten Netzwerte um Größenordnungen überhöht; welche Takte betroffen waren, weiß
    /// die Datei nicht. Netz gilt deshalb als nicht gemessen (`networkBytes` `nil`, `networkSeconds` 0). CPU, Energie,
    /// Datenträger, Messzeit und Gegenstände bleiben.
    private func withoutNetworkBeforeTimestampFix() -> AppUsageHistory {
        var migrated = self
        migrated.networkRevision = Self.currentNetworkRevision
        migrated.hours = hours.map { hour in
            var hour = hour
            hour.networkSeconds = 0
            hour.usage = hour.usage.mapValues { totals in
                var totals = totals
                totals.networkBytes = nil
                return totals
            }
            return hour
        }
        return migrated
    }
}
