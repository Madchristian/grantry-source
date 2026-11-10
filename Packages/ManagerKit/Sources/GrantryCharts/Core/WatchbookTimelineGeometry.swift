import CoreGraphics

/// Geometrie der Wachbuch-Zeitleiste (TM-12.5): Spalten gleicher Breite über den ganzen Zeitraum, je Spalte ein
/// verdichteter Wert. Rein und ohne Uhr, damit Zeitmarke, Lücken und Marken-Gruppen testbar sind.
enum WatchbookTimelineGeometry {
    /// Mitte der Spalte `column`.
    static func x(ofColumn column: Int, count: Int, width: CGFloat) -> CGFloat {
        (CGFloat(column) + 0.5) / CGFloat(max(count, 1)) * width
    }

    /// Spalte unter `x`, an den Rändern begrenzt; `nil` ohne Spalten.
    static func column(atX x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard count > 0, width > 0 else { return nil }
        return min(max(Int((x / width * CGFloat(count)).rounded(.down)), 0), count - 1)
    }

    /// Zeitmarke um `direction` Schritte zu je `step` Spalten verschoben; ohne Zeitmarke beginnt sie am neuesten Wert.
    static func moved(_ column: Int?, by direction: Int, step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let column else { return count - 1 }
        return min(max(column + direction * step, 0), count - 1)
    }

    /// Punkte je zusammenhängendem Abschnitt; `nil` trennt Abschnitte – eine Lücke bleibt leer (§ 3.4). Werte über der
    /// Skala liegen am oberen Rand.
    static func segments(_ values: [Double?], size: CGSize, upperBound: Double) -> [[CGPoint]] {
        var segments: [[CGPoint]] = [], current: [CGPoint] = []
        let upper = max(upperBound, .ulpOfOne)
        for (column, value) in values.enumerated() {
            guard let value else {
                if !current.isEmpty { segments.append(current) }
                current = []
                continue
            }
            let share = min(max(value / upper, 0), 1)
            current.append(CGPoint(x: x(ofColumn: column, count: values.count, width: size.width),
                                   y: size.height * (1 - CGFloat(share))))
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Marken, deren Abstand unter `spacing` liegt, als eine Gruppe am Ort der ersten; aufsteigend nach Beginn.
    struct MarkGroup: Equatable {
        let x: CGFloat
        let marks: [WatchbookMarkContent]

        var first: WatchbookMarkContent { marks[0] }
    }

    static func groups(_ marks: [WatchbookMarkContent], width: CGFloat, spacing: CGFloat) -> [MarkGroup] {
        var groups: [MarkGroup] = []
        for mark in marks.sorted(by: { $0.start < $1.start }) {
            let x = CGFloat(mark.start) * width
            if let last = groups.last, x - last.x < spacing {
                groups[groups.count - 1] = MarkGroup(x: last.x, marks: last.marks + [mark])
            } else {
                groups.append(MarkGroup(x: x, marks: [mark]))
            }
        }
        return groups
    }

    /// Abschnitte gleichen Tons des Thermikbands; Spalten ohne Messung bleiben aus.
    struct Run: Equatable {
        let columns: Range<Int>
        let tone: StatusTone
    }

    static func runs(_ tones: [StatusTone?]) -> [Run] {
        var runs: [Run] = []
        for (column, tone) in tones.enumerated() {
            guard let tone else { continue }
            if let last = runs.last, last.tone == tone, last.columns.upperBound == column {
                runs[runs.count - 1] = Run(columns: last.columns.lowerBound..<column + 1, tone: tone)
            } else {
                runs.append(Run(columns: column..<column + 1, tone: tone))
            }
        }
        return runs
    }
}
