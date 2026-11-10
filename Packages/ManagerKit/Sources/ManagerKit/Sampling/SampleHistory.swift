/// Ringpuffer einer Metrik, älteste zuerst; `nil` = in diesem Takt nicht gemessen. Anhängen ist O(1).
public struct MetricSeries: Sendable {
    public let capacity: Int
    private var storage: [Double?] = []
    /// Index des ältesten Werts, sobald der Puffer voll ist.
    private var head = 0
    /// Takte seit dem letzten gemessenen Wert.
    private(set) var trailingGap = 0

    init(capacity: Int) {
        precondition(capacity > 0, "Kapazität muss positiv sein")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ value: Double?) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
        trailingGap = value == nil ? trailingGap + 1 : 0
    }

    public var values: [Double?] { Array(storage[head...] + storage[..<head]) }

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
        series = series.filter { !$0.value.hasNoValues }
        recordedCount += 1
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
        series = series.filter { !$0.value.hasNoValues }
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
        guard let values = series[key]?.values, !values.isEmpty else {
            return HistoryPoints(values: [], spacing: spacing, latestOffset: .zero)
        }
        // Alle Reihen enden am letzten Takt; ihr erster Wert liegt `values.count - 1` Takte davor.
        let lastTakt = recordedCount - 1, firstTakt = recordedCount - values.count
        let lastBucket = lastTakt / bucketSize
        let firstBucket = max(firstTakt / bucketSize, lastBucket - Self.displayedPointCount + 1)
        let points = (firstBucket...lastBucket).map { bucket -> Double? in
            let start = max(bucket * bucketSize, firstTakt), end = min((bucket + 1) * bucketSize, lastTakt + 1)
            let measured = (start..<end).compactMap { values[$0 - firstTakt] }
            return measured.isEmpty ? nil : measured.reduce(0, +) / Double(measured.count)
        }
        return HistoryPoints(values: points, spacing: spacing,
                             latestOffset: interval * (lastTakt - lastBucket * bucketSize))
    }

    private static func taktCount(in duration: Duration, interval: Duration) -> Int {
        max(1, Int((duration / interval).rounded(.up)))
    }
}
