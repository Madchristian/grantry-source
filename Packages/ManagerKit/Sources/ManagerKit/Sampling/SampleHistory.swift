/// Die letzten `capacity` Werte einer Metrik, älteste zuerst; `nil` = in diesem Takt nicht gemessen. Anhängen ist O(1).
///
/// Gespeichert in Blöcken (#663): volle Blöcke sind unveränderlich und werden zwischen Ständen geteilt, nur der jüngste
/// wächst. Jeder Frame gibt den Verlauf an den Main Actor weiter und hält ihn bis zum nächsten Takt; ein Ringpuffer am
/// Stück wurde deshalb je Takt per Copy-on-Write ganz kopiert – in „Details“ rund 1 200 Prozesse zu je 16 KB – und jeder
/// weitere Halter (Ansichten, Bedienungshilfen) hielt eine ganze Kopie fest. Jetzt kopiert ein Takt je Reihe höchstens
/// den jüngsten Block.
public struct MetricSeries: Sendable {
    /// Voller, unveränderlicher Block; geteilt zwischen allen Ständen, die ihn enthalten.
    private final class Block: Sendable {
        let values: [Double?]

        init(_ values: [Double?]) {
            self.values = values
        }
    }

    /// Eine Minute bei 1 s Takt: Ein Takt kopiert höchstens so viele Werte, ein Stand aus 15 Minuten hat 15 Blöcke.
    static let defaultBlockSize = 60

    public let capacity: Int
    private let blockSize: Int
    /// Volle Blöcke, älteste zuerst.
    private var blocks: [Block] = []
    /// Abgelaufene Werte am Anfang des ältesten Blocks.
    private var dropped = 0
    /// Jüngster Block, noch nicht voll.
    private var tail: [Double?] = []
    /// Takte seit dem letzten gemessenen Wert.
    private(set) var trailingGap = 0

    init(capacity: Int, blockSize: Int = MetricSeries.defaultBlockSize) {
        precondition(capacity > 0, "Kapazität muss positiv sein")
        precondition(blockSize > 0, "Blockgröße muss positiv sein")
        self.capacity = capacity
        // Höchstens die Kapazität: So liegt jeder abgelaufene Wert in einem vollen Block.
        self.blockSize = min(blockSize, capacity)
    }

    /// Anzahl der Werte, höchstens `capacity`.
    var count: Int { blocks.count * blockSize - dropped + tail.count }

    mutating func append(_ value: Double?) {
        tail.append(value)
        if tail.count == blockSize {
            blocks.append(Block(tail))
            tail = []
        }
        if count > capacity {
            dropped += 1
            if dropped == blockSize {
                blocks.removeFirst()
                dropped = 0
            }
        }
        trailingGap = value == nil ? trailingGap + 1 : 0
    }

    public var values: [Double?] { suffix(count) }

    /// Die neuesten `length` Werte, älteste zuerst; ohne die übrigen zu kopieren.
    func suffix(_ length: Int) -> [Double?] {
        var skip = count - min(max(length, 0), count) + dropped
        var result: [Double?] = []
        result.reserveCapacity(count + dropped - skip)
        for block in blocks {
            if skip >= blockSize {
                skip -= blockSize
                continue
            }
            result.append(contentsOf: block.values[skip...])
            skip = 0
        }
        result.append(contentsOf: tail[skip...])
        return result
    }

    /// Kennungen der vollen Blöcke, älteste zuerst – für Tests der geteilten Speicherung.
    var fullBlocks: [ObjectIdentifier] { blocks.map(ObjectIdentifier.init) }

    /// Im ganzen Zeitraum nichts gemessen (z. B. beendeter Prozess).
    var hasNoValues: Bool { trailingGap >= capacity }
}

extension MetricSeries: Equatable {
    public static func == (lhs: MetricSeries, rhs: MetricSeries) -> Bool {
        lhs.capacity == rhs.capacity && lhs.values == rhs.values
    }
}

/// Punkte einer Metrik für einen Graphen, älteste zuerst; jeder Punkt fasst einen Abschnitt von `spacing` zusammen.
/// Abschnitte liegen auf einem festen Takt-Raster, damit Punkte beim nächsten Takt nicht wandern; nur der neueste füllt
/// sich noch und beginnt `latestOffset` vor dem letzten Takt.
public struct HistoryPoints: Equatable, Sendable {
    public let values: [Double?]
    public let spacing: Duration
    public let latestOffset: Duration

    public init(values: [Double?], spacing: Duration, latestOffset: Duration) {
        self.values = values
        self.spacing = spacing
        self.latestOffset = latestOffset
    }
}

/// Verlauf aller Metriken über 15 Minuten, nur im Speicher (Spec §3). Für die Graphen rechnet `pointSeries(for:in:)`
/// auf höchstens `displayedPointCount` Punkte herunter.
public struct SampleHistory: Equatable, Sendable {
    public static let span: Duration = .seconds(900)
    public static let displayedPointCount = 60

    public let interval: Duration
    public private(set) var series: [MetricKey: MetricSeries] = [:]
    /// Alle bisher eingetragenen Takte; Bezug des Abschnitt-Rasters.
    private var recordedCount = 0

    public init(interval: Duration) {
        precondition(interval > .zero, "Takt muss positiv sein")
        self.interval = interval
    }

    var capacity: Int { Self.taktCount(in: Self.span, interval: interval) }

    /// Trägt einen Takt ein: neue Metriken beginnen hier, fehlende bekommen eine Lücke; Metriken ohne Wert im ganzen
    /// Zeitraum entfallen.
    public mutating func record(_ values: [MetricKey: Double]) {
        let capacity = capacity
        for key in series.keys where values[key] == nil {
            series[key]?.append(nil)
        }
        for (key, value) in values {
            series[key, default: MetricSeries(capacity: capacity)].append(value)
        }
        dropSeriesWithoutValues()
        recordedCount += 1
    }

    /// Entfernt Metriken ohne Wert im ganzen Zeitraum; baut das Verzeichnis nur neu, wenn es eine gibt.
    private mutating func dropSeriesWithoutValues() {
        guard series.values.contains(where: \.hasNoValues) else { return }
        series = series.filter { !$0.value.hasNoValues }
    }

    /// Trägt `count` Takte ohne Messung ein, etwa für die Zeit, in der der Task-Manager verdeckt war: Die Graphen zeigen
    /// dort eine Lücke („nicht gemessen“) statt neu zu beginnen (Bewertung 2026.11.7, Mangel 7). Was danach älter als
    /// `span` ist, entfällt.
    public mutating func recordGap(_ count: Int) {
        guard count > 0 else { return }
        let gap = min(count, capacity)
        for key in series.keys {
            for _ in 0..<gap { series[key]?.append(nil) }
        }
        dropSeriesWithoutValues()
        recordedCount += count
    }

    /// Punkte für `window`, älteste zuerst: je Punkt der Mittelwert seiner Takte, `nil`, wenn keiner gemessen hat.
    public func points(for key: MetricKey, in window: HistoryWindow) -> [Double?] {
        pointSeries(for: key, in: window).values
    }

    /// Punkte für `window` mit Abstand und Lage des neuesten Abschnitts (siehe `HistoryPoints`).
    public func pointSeries(for key: MetricKey, in window: HistoryWindow) -> HistoryPoints {
        let taktCount = Self.taktCount(in: window.duration, interval: interval)
        let bucketSize = max(1, Int((Double(taktCount) / Double(Self.displayedPointCount)).rounded(.up)))
        let spacing = interval * bucketSize
        guard let metric = series[key], metric.count > 0 else {
            return HistoryPoints(values: [], spacing: spacing, latestOffset: .zero)
        }
        // Alle Reihen enden am letzten Takt; ihr erster Wert liegt `metric.count - 1` Takte davor.
        let lastTakt = recordedCount - 1, firstTakt = recordedCount - metric.count
        let lastBucket = lastTakt / bucketSize
        let firstBucket = max(firstTakt / bucketSize, lastBucket - Self.displayedPointCount + 1)
        // Nur die Takte ab dem ersten Abschnitt: Eine Zeile von „Details“ braucht 60 der bis zu 900 Werte.
        let firstShown = max(firstBucket * bucketSize, firstTakt)
        let values = metric.suffix(recordedCount - firstShown)
        let points = (firstBucket...lastBucket).map { bucket -> Double? in
            let start = max(bucket * bucketSize, firstTakt), end = min((bucket + 1) * bucketSize, lastTakt + 1)
            let measured = (start..<end).compactMap { values[$0 - firstShown] }
            return measured.isEmpty ? nil : measured.reduce(0, +) / Double(measured.count)
        }
        return HistoryPoints(values: points, spacing: spacing,
                             latestOffset: interval * (lastTakt - lastBucket * bucketSize))
    }

    private static func taktCount(in duration: Duration, interval: Duration) -> Int {
        max(1, Int((duration / interval).rounded(.up)))
    }
}
