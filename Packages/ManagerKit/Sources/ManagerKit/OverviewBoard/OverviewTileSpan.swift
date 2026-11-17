import Foundation

/// Größe einer Kachel des Übersichts-Baukastens in Rasterzellen (Spec 2026-11-09-uebersicht-baukasten § 3). Es gibt nur
/// die fünf Größen aus `all`; gespeichert als Kürzel „2x1“ (Spalten x Zeilen).
public struct OverviewTileSpan: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let columns: Int
    public let rows: Int

    private init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// Ein einzelner Wert: Ring oder Zahl mit Titel.
    public static let small = OverviewTileSpan(columns: 1, rows: 1)
    /// Wert mit kurzem Verlauf oder Pegel.
    public static let wide = OverviewTileSpan(columns: 2, rows: 1)
    /// Wert, Verlauf und Aufschlüsselung.
    public static let large = OverviewTileSpan(columns: 2, rows: 2)
    /// Leiste über die ganze Breite: langer Verlauf, Ringe in einer Reihe.
    public static let banner = OverviewTileSpan(columns: 4, rows: 1)
    /// Tafel über die ganze Breite.
    public static let panel = OverviewTileSpan(columns: 4, rows: 2)

    /// Alle Größen, aufsteigend.
    public static let all: [OverviewTileSpan] = [.small, .wide, .large, .banner, .panel]

    /// Gespeichertes Kürzel „Spalten x Zeilen“.
    public var code: String { "\(columns)x\(rows)" }

    /// Nur die Größen aus `all`; sonst `nil`.
    public init?(code: String) {
        guard let span = Self.all.first(where: { $0.code == code }) else { return nil }
        self = span
    }

    public var cellCount: Int { columns * rows }

    /// „2 × 1“ für Menüs und VoiceOver.
    public var description: String { "\(columns) × \(rows)" }

    /// Nach Fläche, bei gleicher Fläche die schmalere zuerst.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.cellCount, lhs.columns) < (rhs.cellCount, rhs.columns)
    }

    /// Größe, auf die ein Griff einrastet: die erlaubte mit dem kleinsten Abstand zur gezogenen Größe in Zellen; bei
    /// gleichem Abstand die kleinere.
    public static func nearest(columns: Double, rows: Double, among allowed: [OverviewTileSpan]) -> OverviewTileSpan? {
        allowed.sorted().min { distance($0, columns, rows) < distance($1, columns, rows) }
    }

    private static func distance(_ span: OverviewTileSpan, _ columns: Double, _ rows: Double) -> Double {
        let width = Double(span.columns) - columns
        let height = Double(span.rows) - rows
        return width * width + height * height
    }
}

extension OverviewTileSpan: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        guard let span = Self(code: code) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unbekannte Kachelgröße \(code)")
        }
        self = span
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}
