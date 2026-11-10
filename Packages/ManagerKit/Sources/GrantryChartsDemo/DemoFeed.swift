import Foundation
import GrantryCharts
import Observation

/// Fake-Messwerte für den Prototyp (TM-2.9): Wellen mit Rauschen und gelegentlichen Lastspitzen, einmal pro Sekunde;
/// beim Start mit zwei Minuten Vorlauf, damit die Graphen sofort gefüllt sind.
@MainActor
@Observable
final class DemoFeed {
    static let coreKinds: [CoreGrid.Cluster.Kind] = Array(repeating: .performance, count: 8)
        + Array(repeating: .efficiency, count: 4)
    static let capacity = 900
    static let memoryTotal = 32.0 * 1_073_741_824

    private(set) var latest = Date()
    private(set) var cores: [[Double?]] = Array(repeating: [], count: coreKinds.count)
    /// App, zugeordnet, komprimiert, Cache.
    private(set) var memoryLayers: [[Double?]] = Array(repeating: [], count: 4)
    private(set) var diskRead: [Double?] = []
    private(set) var diskWrite: [Double?] = []
    private(set) var received: [Double?] = []
    private(set) var sent: [Double?] = []
    private(set) var gpu: [Double?] = []

    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var random = SplitMix(seed: 42)
    @ObservationIgnored private var timer: Timer?

    init() {
        for _ in 0..<120 { advance() }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    var cpuTotal: [Double?] { average(of: Array(cores.indices)) }

    /// Mittel der Kerne `indices` je Zeitpunkt.
    func average(of indices: [Int]) -> [Double?] {
        (0..<(cores.first?.count ?? 0)).map { index in
            let values = indices.compactMap { cores[$0][index] }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    /// Je Kernart ein Cluster für „Pro Kern“.
    var clusters: [CoreGrid.Cluster] {
        [(CoreGrid.Cluster.Kind.performance, "Leistungskerne"), (.efficiency, "Effizienzkerne")].map { kind, title in
            let indices = Self.coreKinds.indices.filter { Self.coreKinds[$0] == kind }
            let average = average(of: indices)
            let value = (average.last ?? nil).map { "\(Int(($0 * 100).rounded())) %" } ?? "–"
            return CoreGrid.Cluster(kind: kind, title: title, detail: "\(indices.count) Kerne", value: value,
                                    series: series(average),
                                    cores: indices.map { CoreGrid.Core(id: $0, series: series(cores[$0])) })
        }
    }

    func series(_ values: [Double?]) -> ChartSeries { ChartSeries(values: values, spacing: 1, latest: latest) }

    private func advance() {
        tick += 1
        latest = Date()
        let t = Double(tick)
        let burst = sin(t / 23) > 0.82 ? 0.45 : 0
        for (index, kind) in Self.coreKinds.enumerated() {
            let base = kind == .performance ? 0.28 : 0.12
            let wave = 0.22 * sin(t / 7 + Double(index)) + 0.1 * sin(t / 2.3 + Double(index) * 0.7)
            append(clamp(base + wave + burst * (kind == .performance ? 1 : 0.5) + random.noise(0.08)), to: &cores[index])
        }
        let gib = 1_073_741_824.0
        let app = (11 + 2 * sin(t / 40) + random.noise(0.2)) * gib
        append(app, to: &memoryLayers[0])
        append((3.2 + random.noise(0.05)) * gib, to: &memoryLayers[1])
        append((2.4 + 0.8 * sin(t / 60)) * gib, to: &memoryLayers[2])
        append((6 + random.noise(0.3)) * gib, to: &memoryLayers[3])
        append(max(0, 40e6 * pow(max(0, sin(t / 9)), 6) + random.noise(3e6)), to: &diskRead)
        append(max(0, 18e6 * pow(max(0, sin(t / 13 + 1)), 4) + random.noise(2e6)), to: &diskWrite)
        append(max(0, 6e6 + 5e6 * sin(t / 5) + random.noise(1e6)), to: &received)
        append(max(0, 1.2e6 + 1e6 * sin(t / 8) + random.noise(3e5)), to: &sent)
        append(clamp(0.18 + 0.5 * pow(max(0, sin(t / 17)), 3) + random.noise(0.05)), to: &gpu)
    }

    private func append(_ value: Double, to values: inout [Double?]) {
        values.append(value)
        if values.count > Self.capacity { values.removeFirst(values.count - Self.capacity) }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// Kleiner deterministischer Zufallsgenerator, damit der Prototyp bei jedem Start gleich aussieht.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    /// Gleichverteilt in −amplitude…amplitude.
    mutating func noise(_ amplitude: Double) -> Double { (next() * 2 - 1) * amplitude }
}
