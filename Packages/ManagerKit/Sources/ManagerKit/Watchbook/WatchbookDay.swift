import Foundation

/// Ein Tag des Wachbuchs und damit eine Datei. Tage sind **UTC-Tage**, unabhängig von der Zeitzone des Macs: Ein
/// Zeitzonenwechsel oder das Ende der Sommerzeit verschiebt sonst Tagesgrenzen, sodass ein Datum doppelt oder gar nicht
/// vorkäme. Die Ansicht rechnet mit absoluten Zeitpunkten und stellt sie in Ortszeit dar.
public struct WatchbookDay: Hashable, Comparable, Sendable {
    static let fileExtension = "watchbook"
    private static let seconds: TimeInterval = 86_400
    private static let dateFormat = Date.ISO8601FormatStyle().year().month().day()

    /// Tage seit dem 1. Januar 1970 (UTC).
    public let index: Int

    public init(index: Int) {
        self.index = index
    }

    public init(containing date: Date) {
        index = Int((date.timeIntervalSince1970 / Self.seconds).rounded(.down))
    }

    /// Aus einem Dateinamen wie `2026-11-07.watchbook`; `nil` für jeden anderen Namen (auch ungültige Daten).
    init?(fileName: String) {
        let suffix = "." + Self.fileExtension
        guard fileName.hasSuffix(suffix) else { return nil }
        let stamp = String(fileName.dropLast(suffix.count))
        guard stamp.count == 10, let date = try? Date(stamp, strategy: Self.dateFormat) else { return nil }
        self.init(containing: date)
        // Nur die kanonische Schreibweise; `2026-02-30` würde sonst als 2. März gelesen.
        guard self.fileName == fileName else { return nil }
    }

    public var start: Date { Date(timeIntervalSince1970: Double(index) * Self.seconds) }
    public var end: Date { Date(timeIntervalSince1970: Double(index + 1) * Self.seconds) }

    var fileName: String { "\(start.formatted(Self.dateFormat)).\(Self.fileExtension)" }

    public static func < (lhs: WatchbookDay, rhs: WatchbookDay) -> Bool { lhs.index < rhs.index }
}
