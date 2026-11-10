import Foundation

/// Taktverteilung je Cluster über `span` vor der jüngsten Messung (TM-14.3): Eine Messung des Helpers deckt nur 0,5 s
/// ab und springt von Messung zu Messung; gesammelt wird jede mit ihrer aktiven Zeit gewichtet, damit Ruhephasen die
/// Verteilung unter Last nicht verwässern. Nur im Speicher, höchstens `maximumEntries` Messungen.
public struct ClockDistributionHistory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let time: Date
        let clusters: [SensorReading.Cluster]
    }

    public static let span: TimeInterval = 60
    /// Bei 2 s Abstand reichen 30; mehr nur, wenn Messungen dichter kommen.
    static let maximumEntries = 64

    private var entries: [Entry] = []

    public init() {}

    public var count: Int { entries.count }

    /// Trägt eine Messung ein und vergisst, was älter als `span` vor ihr ist.
    public mutating func record(_ reading: SensorReading, at time: Date) {
        let clusters = reading.clusters.filter { !$0.frequencySteps.isEmpty }
        let oldest = time.addingTimeInterval(-Self.span)
        entries.removeAll { $0.time < oldest }
        entries.append(Entry(time: time, clusters: clusters))
        entries.removeFirst(max(entries.count - Self.maximumEntries, 0))
    }

    /// Gesammelte Anteile je Taktstufe, aufsteigend nach Takt, zusammen 1; leer, wenn der Cluster nie aktiv war.
    /// Ohne aktive Zeit (fehlt oder 0 in allen Messungen) zählt jede Messung gleich.
    public func steps(ofCluster name: String) -> [SensorReading.FrequencyStep] {
        let matches = entries.compactMap { entry in entry.clusters.first { $0.name == name } }
        guard !matches.isEmpty else { return [] }
        let weights = matches.map { max($0.activeShare ?? 0, 0) }
        let total = weights.reduce(0, +)
        var shares: [Double: Double] = [:]
        for (cluster, weight) in zip(matches, weights) {
            for step in cluster.frequencySteps {
                shares[step.frequencyMHz, default: 0] += step.share * (total > 0 ? weight : 1)
            }
        }
        let sum = shares.values.reduce(0, +)
        guard sum > 0 else { return [] }
        return shares.sorted { $0.key < $1.key }
            .map { SensorReading.FrequencyStep(frequencyMHz: $0.key, share: $0.value / sum) }
    }
}
