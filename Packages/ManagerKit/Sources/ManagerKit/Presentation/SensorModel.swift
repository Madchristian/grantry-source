import Foundation
import Observation
import os

/// Sensoren des Leistung-Tabs (TM-9.4) über den Helper (Muster `ForeignProcessUsageModel`): fragt `readSensors` nur
/// zwischen `start()` und `stop()` – die Oberfläche koppelt beides an die Sichtbarkeit des Tabs – und erst `interval`
/// nach der letzten Antwort. Ein Helper-Lauf dauert ≥ 0,5 s (Messfenster von `powermetrics`). Scheitert er, bleibt
/// `reading` leer (keine Sensor-Kachel); gemeldet wird das einmal je Lebensdauer. Nichts wird gespeichert.
@MainActor
@Observable
public final class SensorModel {
    public nonisolated static let interval: Duration = .seconds(2)
    private nonisolated static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "task-manager")

    /// Letzte Messung; `nil`, solange nicht gemessen wird oder der Helper nichts liefert.
    public private(set) var reading: SensorReading?
    /// Leistungsaufnahme in Watt (`MetricKey.power`, `.cpuPower`, `.gpuPower`, `.neuralEnginePower`) im Takt `interval`,
    /// 15 min, nur im Speicher.
    public private(set) var history = SampleHistory(interval: SensorModel.interval)
    /// Taktverteilung je Cluster der letzten 60 s (Chip-Tab, TM-14.3), nur im Speicher.
    public private(set) var clockHistory = ClockDistributionHistory()
    /// Ankunft der letzten Messung (Zeitbezug des Graphen).
    public private(set) var measuredAt = Date.distantPast
    /// Nach jeder Antwort des Helpers, etwa für die Regel „Drosselung“ (`TaskManagerModel.record(sensors:)`); `nil`,
    /// wenn er nichts lieferte.
    @ObservationIgnored public var onReading: (@MainActor (SensorReading?) -> Void)?

    @ObservationIgnored private let source: (any PrivilegedSensorReading)?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var reportedFailure = false

    /// - Parameter source: `nil` ohne Helper – dann misst das Model nie.
    public init(
        source: (any PrivilegedSensorReading)?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.sleep = sleep
        self.now = now
    }

    isolated deinit {
        task?.cancel()
    }

    public var isRunning: Bool { task != nil }

    /// Alles, was die Ansichten zeigen, auf einmal – für den Takt des Task-Managers (`FrameLatch`, #481).
    public var snapshot: SensorSnapshot {
        SensorSnapshot(reading: reading, history: history, clockHistory: clockHistory, measuredAt: measuredAt)
    }

    /// Misst sofort und dann jeweils `interval` nach der letzten Antwort, bis `stop()`.
    public func start() {
        guard task == nil, let source else { return }
        let sleep = sleep
        task = Task { [weak self] in
            while !Task.isCancelled {
                let result: Result<SensorReading, any Error>
                do { result = .success(try await source.sensorReading()) } catch { result = .failure(error) }
                SamplingTrace.tick(.sensors)
                guard !Task.isCancelled else { return }
                self?.apply(result)
                do { try await sleep(Self.interval) } catch { return }
            }
        }
    }

    /// Hört auf und vergisst Messung, Verlauf und Taktverteilung; ein laufender Helper-Aufruf endet von selbst.
    public func stop() {
        task?.cancel()
        task = nil
        reading = nil
        history = SampleHistory(interval: Self.interval)
        clockHistory = ClockDistributionHistory()
    }

    func apply(_ result: Result<SensorReading, any Error>) {
        switch result {
        case .success(let reading) where !reading.isEmpty:
            self.reading = reading
            var watts: [MetricKey: Double] = [:]
            watts[.power] = reading.combinedMilliwatts.map { $0 / 1000 }
            watts[.cpuPower] = reading.cpuMilliwatts.map { $0 / 1000 }
            watts[.gpuPower] = reading.gpuMilliwatts.map { $0 / 1000 }
            watts[.neuralEnginePower] = reading.aneMilliwatts.map { $0 / 1000 }
            history.record(watts)
            measuredAt = now()
            clockHistory.record(reading, at: measuredAt)
        case .success:
            reading = nil
        case .failure(let error):
            reading = nil
            if !reportedFailure {
                reportedFailure = true
                Self.logger.error("Sensoren nicht lesbar: \(error.readableDescription, privacy: .public)")
            }
        }
        onReading?(reading)
    }
}

/// Stand von `SensorModel` zu einem Zeitpunkt.
public struct SensorSnapshot: Sendable {
    public static let empty = SensorSnapshot(reading: nil, history: SampleHistory(interval: SensorModel.interval),
                                             clockHistory: ClockDistributionHistory(), measuredAt: .distantPast)

    public let reading: SensorReading?
    public let history: SampleHistory
    public let clockHistory: ClockDistributionHistory
    public let measuredAt: Date

    /// Neu ist eine weitere Messung oder ihr Ende (`stop()`, Helper liefert nichts); Verläufe vergleicht das nicht.
    public func isNew(comparedTo other: SensorSnapshot) -> Bool {
        measuredAt != other.measuredAt || (reading == nil) != (other.reading == nil)
    }
}
