import Foundation

/// Ländertabelle aus dem App-Paket (#630): ordnet einer öffentlichen IPv4- oder IPv6-Adresse offline den Ländercode
/// ihres Adressblocks zu. Kein Netzverkehr, kein Nachladen – neue Daten kommen nur mit einem App-Update.
///
/// Die Datei wird per Speicherabbild geöffnet und binär durchsucht; im Arbeitsspeicher liegen nur die berührten Seiten.
/// Format und Herkunft: `scripts/country_table.py` und docs/laenderdaten.md. IPv6 ist bis /64 aufgelöst; ein /64, das
/// die Quelle auf mehrere Länder verteilt, hat keinen Eintrag.
public struct CountryTable: Sendable {
    public enum LoadError: Error, Equatable {
        /// Datei fehlt oder ist nicht lesbar.
        case unreadable
        /// Kennung, Größe oder Aufbau passen nicht zum Format.
        case malformed
    }

    /// Name der Datei in den Ressourcen des App-Pakets.
    public static let resourceName = "CountryTable"
    public static let resourceExtension = "bin"

    /// Stand der Daten an der Quelle.
    public let dataDate: DateComponents

    private let data: Data
    private let codes: Section
    private let v4: Family
    private let v6: Family

    /// Lage eines Abschnitts in der Datei.
    private struct Section: Sendable {
        let offset: Int
        let count: Int
    }

    /// Abschnitte einer Adressfamilie: aufsteigende Anfänge und je Abschnitt ein Länderindex.
    private struct Family: Sendable {
        let starts: Section
        let indices: Section
    }

    private static let magic = Data("GRCTRY01".utf8)
    private static let headerSize = 32
    private static let codeSize = 2

    /// Öffnet die Tabelle als Speicherabbild.
    public init(contentsOf url: URL) throws(LoadError) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { throw .unreadable }
        try self.init(data: data)
    }

    public init(data: Data) throws(LoadError) {
        guard data.count >= Self.headerSize, data.prefix(Self.magic.count) == Self.magic else { throw .malformed }
        let header = (0..<4).map { Int(Self.load(UInt32.self, from: data, at: Self.magic.count + 4 * $0)) }
        let (date, codeCount, v4Count, v6Count) = (header[0], header[1], header[2], header[3])
        var offset = Self.headerSize
        func section(count: Int, stride: Int) -> Section {
            defer { offset += (count * stride + 7) / 8 * 8 }
            return Section(offset: offset, count: count)
        }
        codes = section(count: codeCount, stride: Self.codeSize)
        v4 = Family(starts: section(count: v4Count, stride: 4), indices: section(count: v4Count, stride: 1))
        v6 = Family(starts: section(count: v6Count, stride: 8), indices: section(count: v6Count, stride: 1))
        // Jede Adresse braucht einen Abschnitt davor: beide Familien beginnen bei 0.
        guard offset == data.count, codeCount >= 1, codeCount <= 256, v4Count >= 1, v6Count >= 1,
              Self.load(UInt32.self, from: data, at: v4.starts.offset) == 0,
              Self.load(UInt64.self, from: data, at: v6.starts.offset) == 0 else { throw .malformed }
        self.data = data
        dataDate = DateComponents(year: date / 10_000, month: date / 100 % 100, day: date % 100)
    }

    /// ISO-3166-Code (zwei Großbuchstaben) des Adressblocks; `nil` ohne Eintrag und für alles, was keine Adresse ist.
    /// IPv4-mapped und NAT64 werden über die eingebettete IPv4-Adresse aufgelöst.
    public func countryCode(for address: String) -> String? {
        NumericIPAddress(address).flatMap(countryCode)
    }

    func countryCode(for address: NumericIPAddress) -> String? {
        let index: UInt8
        if let embedded = address.embeddedV4 {
            index = self.index(in: v4, for: embedded)
        } else if case .v6(let high, _) = address {
            index = self.index(in: v6, for: high)
        } else {
            return nil
        }
        guard index != 0, Int(index) < codes.count else { return nil }
        let offset = codes.offset + Int(index) * Self.codeSize
        return String(decoding: data[data.startIndex + offset..<data.startIndex + offset + Self.codeSize],
                      as: UTF8.self)
    }

    /// Länderindex des letzten Abschnitts, der bei `key` oder davor beginnt.
    private func index<Key: FixedWidthInteger>(in family: Family, for key: Key) -> UInt8 {
        var low = 0
        var high = family.starts.count
        while high - low > 1 {
            let middle = (low + high) / 2
            let start = Self.load(Key.self, from: data, at: family.starts.offset + middle * MemoryLayout<Key>.size)
            if start <= key { low = middle } else { high = middle }
        }
        return data[data.startIndex + family.indices.offset + low]
    }

    private static func load<Value: FixedWidthInteger>(_: Value.Type, from data: Data, at offset: Int) -> Value {
        data.withUnsafeBytes { Value(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Value.self)) }
    }
}
