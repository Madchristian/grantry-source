import Foundation

/// Anzeige des laufenden Vollscans; die Quellenabdeckung bleibt unabhängig davon im Snapshot sichtbar.
public struct ScanProgress: Sendable, Equatable {
    public let fraction: Double
    private let estimatedRemainingSeconds: TimeInterval?
    public let estimateExpiresAt: ContinuousClock.Instant?

    /// Auch eine unverändert gespeicherte Prognose verfällt ohne weitere Quellenereignisse.
    public var remainingSeconds: TimeInterval? { remainingSeconds(at: .now) }

    public func remainingSeconds(at now: ContinuousClock.Instant) -> TimeInterval? {
        guard let estimateExpiresAt, now < estimateExpiresAt else { return nil }
        return estimatedRemainingSeconds
    }

    public init(fraction: Double = 0, remainingSeconds: TimeInterval? = nil,
                now: ContinuousClock.Instant = .now) {
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let estimate = remainingSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.estimatedRemainingSeconds = estimate
        self.estimateExpiresAt = estimate.map { now.advanced(by: .seconds($0)) }
    }
}

/// Ein Messsatz des letzten erfolgreichen Vollscans, kein Verlauf und keine Messungen je Datensatz.
struct ScanDurations: Sendable, Codable, Equatable {
    let sources: [SourceID: TimeInterval]
    let processing: TimeInterval

    var isValid: Bool {
        sources.count <= 32 && processing.isFinite && processing > 0 && processing < 86_400
            && sources.values.allSatisfy { $0.isFinite && $0 > 0 && $0 < 86_400 }
    }
}

/// Rein ereignisgetrieben: nur echte Quellenabschlüsse erhöhen den Fortschritt. Kein Zeitgeber, keine Systemabfrage.
/// Quellen laufen parallel; die Restdauer folgt deshalb dem längsten offenen Schritt plus Nachverarbeitung.
struct ScanProgressTracker: Sendable {
    private let sources: Set<SourceID>
    private let previous: ScanDurations?
    private var durations: [SourceID: TimeInterval] = [:]
    private var failed = false
    private var ended = false
    private var lastPublication: TimeInterval = 0
    private(set) var progress = ScanProgress()
    private(set) var completedDurations: ScanDurations?

    init(sources: Set<SourceID>, previous: ScanDurations?) {
        self.sources = sources
        self.previous = previous.flatMap {
            $0.isValid && Set($0.sources.keys) == sources ? $0 : nil
        }
    }

    /// Liefert, ob die Engine veröffentlichen darf (höchstens 4/s). Auch unterdrückte Ereignisse zählen intern.
    @discardableResult
    mutating func complete(_ source: SourceID, elapsed: TimeInterval, succeeded: Bool) -> Bool {
        guard !ended, sources.contains(source), durations[source] == nil, elapsed.isFinite, elapsed >= 0 else { return false }
        durations[source] = max(0.000_001, elapsed)
        failed = failed || !succeeded
        let fraction: Double
        if let previous {
            let total = previous.sources.values.reduce(previous.processing, +)
            fraction = durations.keys.reduce(0) { $0 + (previous.sources[$1] ?? 0) } / total
        } else {
            fraction = Double(durations.count) / Double(sources.count + 1)
        }
        progress = ScanProgress(fraction: max(progress.fraction, min(0.99, fraction)),
                                remainingSeconds: remaining(at: elapsed))
        guard elapsed - lastPublication >= 0.25 else { return false }
        lastPublication = elapsed
        return true
    }

    private func remaining(at elapsed: TimeInterval) -> TimeInterval? {
        guard !failed, let previous, !durations.isEmpty else { return nil }
        let ratios = durations.map { $0.value / previous.sources[$0.key]! }
        guard let fastest = ratios.min(), let slowest = ratios.max(),
              fastest >= 0.25, slowest <= 4, slowest / fastest <= 2 else { return nil }
        let measured = durations.values.reduce(0, +)
        let expected = durations.keys.reduce(0) { $0 + previous.sources[$1]! }
        let pace = measured / expected
        let pending = sources.subtracting(durations.keys)
        let longest = pending.map { previous.sources[$0]! * pace }.max() ?? elapsed
        // Ein bereits überzogener offener Schritt macht die Prognose unzuverlässig.
        guard pending.isEmpty || longest > elapsed else { return nil }
        return max(0, longest - elapsed) + previous.processing * pace
    }

    mutating func finish(elapsed: TimeInterval) {
        guard !ended else { return }
        ended = true
        progress = ScanProgress(fraction: 1)
        if !failed, durations.count == sources.count {
            completedDurations = ScanDurations(sources: durations,
                processing: max(0.000_001, elapsed - (durations.values.max() ?? 0)))
        }
    }

    mutating func cancel() {
        ended = true
        progress = ScanProgress(fraction: progress.fraction)
        completedDurations = nil
    }
}

/// Kleine optionale Optimierungsdatei. Defekte/zu große Daten bedeuten einen ersten Scan ohne Prognose.
struct ScanDurationStore: Sendable {
    let url: URL?

    func load() -> ScanDurations? {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 8192, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ScanDurations.self, from: data), value.isValid else { return nil }
        return value
    }

    func save(_ value: ScanDurations) {
        guard let url, value.isValid, let data = try? JSONEncoder().encode(value), data.count <= 8192 else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { /* Fortschritt bleibt auch ohne gespeicherte Messung nutzbar. */ }
    }
}

extension Duration {
    var scanSeconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Genau ein Ereignis je abgefragter Quelle, auch bei Fehler/Fristablauf; nie für spätere Hintergrund-Ergebnisse.
public struct ScanSourceCompletion: Sendable {
    public let source: SourceID
    public let elapsed: TimeInterval
    public let succeeded: Bool
}
