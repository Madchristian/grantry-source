import Foundation

/// Anzeige eines laufenden Scans: Vollscan (#238) oder „Scannen“ eines Aufräumen-Segments (#270); die
/// Quellenabdeckung bleibt unabhängig davon im Snapshot sichtbar.
public struct ScanProgress: Sendable, Equatable {
    public let fraction: Double
    /// Zu kurz für sinnvollen Fortschritt: Die Anzeige läuft unbestimmt, aber sichtbar, ohne Restdauer.
    public let isIndeterminate: Bool
    private let estimatedRemainingSeconds: TimeInterval?
    public let estimateExpiresAt: ContinuousClock.Instant?

    /// Auch eine unverändert gespeicherte Prognose verfällt ohne weitere Quellenereignisse.
    public var remainingSeconds: TimeInterval? { remainingSeconds(at: .now) }

    public func remainingSeconds(at now: ContinuousClock.Instant) -> TimeInterval? {
        guard let estimateExpiresAt, now < estimateExpiresAt else { return nil }
        return estimatedRemainingSeconds
    }

    public init(fraction: Double = 0, remainingSeconds: TimeInterval? = nil, isIndeterminate: Bool = false,
                now: ContinuousClock.Instant = .now) {
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        self.isIndeterminate = isIndeterminate
        let estimate = isIndeterminate ? nil : remainingSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.estimatedRemainingSeconds = estimate
        self.estimateExpiresAt = estimate.map { now.advanced(by: .seconds($0)) }
    }
}

/// Wie die Schritte eines Scans laufen; davon hängt ab, was als Dauer eines Schritts zählt.
public enum ScanStepSchedule: Sendable {
    /// Alle Schritte starten gleichzeitig (Quellen des Vollscans): Dauer = Zeit seit Scan-Beginn, die Restdauer folgt
    /// dem längsten offenen Schritt.
    case parallel
    /// Schritte schließen nacheinander ab, auch begrenzt parallel (Speicher-Kategorien, Kennungsgruppen, Prozess-Schritte):
    /// Dauer = Abstand zum vorigen Abschluss, die Restdauer ist die Summe der offenen Schritte.
    case sequential
}

/// Ein Messsatz des letzten erfolgreichen Laufs, kein Verlauf und keine Messungen je Datensatz.
public struct ScanStepDurations<Step: Hashable & Sendable>: Sendable, Equatable {
    public let steps: [Step: TimeInterval]
    public let processing: TimeInterval

    public init(steps: [Step: TimeInterval], processing: TimeInterval) {
        self.steps = steps
        self.processing = processing
    }

    /// Erwartete Zeit bis zum Abschluss von `completed`: nacheinander die Summe, parallel der längste Schritt, weil alle
    /// zugleich beginnen und sich überlappen (#266).
    func duration(of completed: some Sequence<Step>, schedule: ScanStepSchedule) -> TimeInterval {
        let durations = completed.map { steps[$0] ?? 0 }
        return switch schedule {
        case .parallel: durations.max() ?? 0
        case .sequential: durations.reduce(0, +)
        }
    }

    /// Erwartete Dauer des ganzen Laufs bis zum Ende der Nachverarbeitung.
    func total(_ schedule: ScanStepSchedule) -> TimeInterval { duration(of: steps.keys, schedule: schedule) + processing }

    var isValid: Bool {
        steps.count <= 512 && processing.isFinite && processing > 0 && processing < 86_400
            && steps.values.allSatisfy { $0.isFinite && $0 > 0 && $0 < 86_400 }
    }
}

/// Der Schlüssel `sources` bleibt, damit vorhandene `ScanDurations.json` des Vollscans lesbar bleiben.
extension ScanStepDurations: Codable where Step: Codable {
    private enum CodingKeys: String, CodingKey {
        case steps = "sources", processing
    }
}

/// Messsatz des Vollscans je Quelle.
typealias ScanDurations = ScanStepDurations<SourceID>
/// Fortschritt des Vollscans je Quelle.
typealias ScanProgressTracker = ScanStepTracker<SourceID>

extension ScanStepTracker where Step == SourceID {
    /// Vollscan (#266): Die Quellen laufen parallel und sind meist nach Bruchteilen einer Sekunde fertig, die
    /// Nachverarbeitung (Zusammenführen, Signaturen, Ablage, Verlauf) dauert ein Vielfaches. Ohne Messung bekommt sie
    /// deshalb vorsichtig die Hälfte des Balkens statt nur den Anteil einer Quelle.
    init(fullScanOf sources: Set<SourceID>, previous: ScanDurations?) {
        self.init(steps: sources, previous: previous, schedule: .parallel, unmeasuredProcessingShare: 0.5)
    }
}

/// Rein ereignisgetrieben: nur echte Schrittabschlüsse erhöhen den Fortschritt. Kein Zeitgeber, keine Systemabfrage.
/// Gewichtet wird mit den Dauern des letzten erfolgreichen Laufs mit denselben Schritten, sonst zählen die Schritte.
/// Die Nachverarbeitung nach dem letzten Schritt ist ein eigener Abschnitt ohne Zwischenstand: Ihren Anteil erreicht der
/// Balken erst mit `finish`.
public struct ScanStepTracker<Step: Hashable & Sendable>: Sendable {
    /// Darunter dauerte der letzte Lauf zu kurz für sinnvollen Fortschritt: unbestimmte Anzeige.
    public static var minimumDeterminateSeconds: TimeInterval { 1 }

    private let steps: Set<Step>
    private let previous: ScanStepDurations<Step>?
    private let schedule: ScanStepSchedule
    private let unmeasuredProcessingShare: Double?
    private let isIndeterminate: Bool
    private var durations: [Step: TimeInterval] = [:]
    private var lastCompletion: TimeInterval = 0
    private var failed = false
    private var ended = false
    private var lastPublication: TimeInterval = 0
    public private(set) var progress: ScanProgress
    public private(set) var completedDurations: ScanStepDurations<Step>?

    /// `unmeasuredProcessingShare`: Anteil der Nachverarbeitung am Balken, solange keine Messung vorliegt; ohne Angabe
    /// zählt sie wie ein weiterer Schritt.
    public init(steps: Set<Step>, previous: ScanStepDurations<Step>?, schedule: ScanStepSchedule = .parallel,
                unmeasuredProcessingShare: Double? = nil) {
        self.steps = steps
        self.schedule = schedule
        self.unmeasuredProcessingShare = unmeasuredProcessingShare.map { min(1, max(0, $0)) }
        let previous = previous.flatMap { $0.isValid && Set($0.steps.keys) == steps ? $0 : nil }
        self.previous = previous
        isIndeterminate = previous.map { $0.total(schedule) < Self.minimumDeterminateSeconds } ?? false
        progress = ScanProgress(isIndeterminate: isIndeterminate)
    }

    /// Liefert, ob veröffentlicht werden darf (höchstens 4/s). Auch unterdrückte Ereignisse zählen intern.
    @discardableResult
    public mutating func complete(_ step: Step, elapsed: TimeInterval, succeeded: Bool,
                                  now: ContinuousClock.Instant = .now) -> Bool {
        guard !ended, steps.contains(step), durations[step] == nil, elapsed.isFinite, elapsed >= 0 else { return false }
        let duration = switch schedule {
        case .parallel: elapsed
        case .sequential: elapsed - lastCompletion
        }
        durations[step] = max(0.000_001, duration)
        lastCompletion = max(lastCompletion, elapsed)
        failed = failed || !succeeded
        let fraction = if let previous {
            previous.duration(of: durations.keys, schedule: schedule) / previous.total(schedule)
        } else if let unmeasuredProcessingShare {
            Double(durations.count) / Double(steps.count) * (1 - unmeasuredProcessingShare)
        } else {
            Double(durations.count) / Double(steps.count + 1)
        }
        progress = ScanProgress(fraction: max(progress.fraction, min(0.99, fraction)),
                                remainingSeconds: remaining(at: elapsed), isIndeterminate: isIndeterminate, now: now)
        guard elapsed - lastPublication >= 0.25 else { return false }
        lastPublication = elapsed
        return true
    }

    private func remaining(at elapsed: TimeInterval) -> TimeInterval? {
        guard !failed, let previous, !durations.isEmpty else { return nil }
        let measured = durations.values.reduce(0, +)
        let expected = durations.keys.reduce(0) { $0 + previous.steps[$1]! }
        let pace = measured / expected
        let pending = steps.subtracting(durations.keys)
        switch schedule {
        case .parallel:
            let ratios = durations.map { $0.value / previous.steps[$0.key]! }
            guard let fastest = ratios.min(), let slowest = ratios.max(),
                  fastest >= 0.25, slowest <= 4, slowest / fastest <= 2 else { return nil }
            let longest = pending.map { previous.steps[$0]! * pace }.max() ?? elapsed
            // Ein bereits überzogener offener Schritt macht die Prognose unzuverlässig.
            guard pending.isEmpty || longest > elapsed else { return nil }
            return max(0, longest - elapsed) + previous.processing * pace
        case .sequential:
            // Einzelne Abstände schwanken mit der Reihenfolge; belastbar ist nur das Tempo des ganzen Laufs.
            guard (0.5...2).contains(pace) else { return nil }
            return pending.reduce(previous.processing) { $0 + previous.steps[$1]! } * pace
        }
    }

    public mutating func finish(elapsed: TimeInterval) {
        guard !ended else { return }
        ended = true
        progress = ScanProgress(fraction: 1)
        if !failed, durations.count == steps.count {
            let processing = switch schedule {
            case .parallel: elapsed - (durations.values.max() ?? 0)
            case .sequential: elapsed - lastCompletion
            }
            completedDurations = ScanStepDurations(steps: durations, processing: max(0.000_001, processing))
        }
    }

    public mutating func cancel() {
        ended = true
        progress = ScanProgress(fraction: progress.fraction, isIndeterminate: isIndeterminate)
        completedDurations = nil
    }
}

/// Meldung eines Segment-Scans an seine Fortschrittsanzeige (#270): genau ein Abschluss je Schritt, nie für einen
/// abgebrochenen Rest.
public enum ScanStepEvent<Step: Hashable & Sendable>: Sendable, Equatable {
    /// Die Schritte stehen erst während des Laufs fest (Kennungsgruppen der App-Reste); bis dahin läuft die Anzeige
    /// unbestimmt.
    case planned([Step])
    case completed(Step, succeeded: Bool)

    public func map<Other: Hashable & Sendable>(_ transform: (Step) -> Other) -> ScanStepEvent<Other> {
        switch self {
        case .planned(let steps): .planned(steps.map(transform))
        case .completed(let step, let succeeded): .completed(transform(step), succeeded: succeeded)
        }
    }
}

/// Empfänger der Schritte eines Segment-Scans; der Scanner wartet die Meldung ab, damit sie in Reihenfolge ankommt.
public typealias ScanStepHandler<Step: Hashable & Sendable> = @Sendable (ScanStepEvent<Step>) async -> Void

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
    public var scanSeconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Genau ein Ereignis je abgefragter Quelle, auch bei Fehler/Fristablauf; nie für spätere Hintergrund-Ergebnisse.
public struct ScanSourceCompletion: Sendable {
    public let source: SourceID
    public let elapsed: TimeInterval
    public let succeeded: Bool
}
