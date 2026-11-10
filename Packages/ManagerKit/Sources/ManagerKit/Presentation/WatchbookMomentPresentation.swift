import Foundation
import GrantryShared

/// Wohin ein Sprung aus dem Wachbuch führt (TM-12.6, Spec 2026-11-08 § 5.1); die App wählt danach Bereich und Eintrag.
public enum WatchbookJumpTarget: Hashable, Sendable {
    /// Ein Prozess in „Details“ – nur, solange PID und Startzeit noch passen.
    case process(ProcessKey)
    /// Der Verlaufseintrag einer Änderung (ihre ID ist die des Eintrags).
    case historyEntry(UUID)
    case autostart
    case extensions
    case networkConnections

    /// Kennung für die Tafel (`WatchbookJumpContent.id`).
    public var id: String {
        switch self {
        case .process(let key): "process:\(key.id)"
        case .historyEntry(let id): "history:\(id.uuidString)"
        case .autostart: "autostart"
        case .extensions: "extensions"
        case .networkConnections: "network"
        }
    }
}

/// Verbraucher an der Zeitmarke: noch nicht gelesen oder gelesen (`nil` = nicht aufgezeichnet).
public enum WatchbookConsumerState: Equatable, Sendable {
    case loading
    case loaded(WatchbookConsumers?)
}

/// Panel „Zu diesem Zeitpunkt“ und Tabelle „Befunde“ (TM-12.6): was der Mac an der Zeitmarke tat, was sich ±5 min
/// änderte, und der Sprung zum zuständigen Bereich. Rein; ob ein Prozess noch läuft, sagt der Aufrufer
/// (`ProcessInspecting.liveness`).
extension WatchbookPresentation {
    public struct Jump: Equatable, Sendable {
        public let target: WatchbookJumpTarget
        public let title: String
        /// Warum es kein Ziel gibt („ffmpeg läuft nicht mehr.“); dann kein Sprung.
        public let note: String?
    }

    /// Ein laufender Befund oder eine Änderung bzw. ein Systemereignis an der Zeitmarke.
    public struct MomentEntry: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let style: Mark.Style
        public let source: MarkSource?
        public let title: String
        public let time: String
        public let detail: String
        public let jump: Jump?
    }

    public struct MomentConsumer: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        /// „System“ für Systemprozesse, sonst leer.
        public let badge: String
        public let value: String
        public let fraction: Double
    }

    public struct MomentValue: Equatable, Sendable {
        public let title: String
        public let value: String
    }

    public struct Moment: Equatable, Sendable {
        public let time: String
        public let values: [MomentValue]
        public let cpuConsumers: [MomentConsumer]
        public let memoryConsumers: [MomentConsumer]
        public let consumersNote: String?
        public let findings: [MomentEntry]
        public let changes: [MomentEntry]
    }

    /// Eine Zeile der Tabelle „Befunde“.
    public struct FindingRow: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let isCritical: Bool
        public let start: String
        public let duration: String
        public let kind: String
        public let reason: String
        public let cause: String
    }

    static let otherAccountsName = String(localized: "Andere Konten")

    // MARK: Tabelle

    /// Befunde des Zeitraums, neueste zuerst.
    public var findingRows: [FindingRow] {
        guard state == .recorded, let series else { return [] }
        let format = WatchbookTimeFormat(calendar: calendar)
        return series.events.filter { $0.kind == .finding }
            .sorted { $0.start != $1.start ? $0.start > $1.start : $0.id.uuidString < $1.id.uuidString }
            .map { event in
                let duration = event.end.map { Self.compactDuration($0.timeIntervalSince(event.start)) }
                    ?? String(localized: "läuft · \(Self.compactDuration(series.range.upperBound.timeIntervalSince(event.start)))")
                return FindingRow(id: event.id, isCritical: event.tone == .critical,
                                  start: format.weekdayTime(event.start), duration: duration,
                                  kind: Self.findingKindTitle(event), reason: event.summary,
                                  cause: Self.name(of: event.subject) ?? PerformancePresentation.missing)
            }
    }

    /// „Keine Befunde in der letzten Stunde.“
    public var findingsEmptyText: String { String(localized: "Keine Befunde \(period.withinTitle).") }

    /// Zeitmarke für einen gewählten Befund: sein Beginn, für früher begonnene der Anfang des Zeitraums.
    public func markerTime(ofFinding id: UUID) -> Date? {
        guard let series, let event = series.events.first(where: { $0.id == id && $0.kind == .finding }) else {
            return nil
        }
        return min(max(event.start, series.range.lowerBound), series.range.upperBound)
    }

    // MARK: Panel

    /// Inhalt des Panels an Spalte `column`; `nil` ohne Aufzeichnung oder außerhalb der Reihe.
    public func moment(at column: Int, consumers: WatchbookConsumerState,
                       liveness: (ProcessKey) -> ProcessLiveness) -> Moment? {
        guard state == .recorded, let series, (0..<series.width).contains(column) else { return nil }
        let format = WatchbookTimeFormat(calendar: calendar)
        let time = series.time(ofColumn: column)
        let columnRange = series.range.lowerBound.addingTimeInterval(Double(column) * series.columnDuration)
            ..< series.range.lowerBound.addingTimeInterval(Double(column + 1) * series.columnDuration)
        let around = WatchbookEvent.range(around: time, within: max(WatchbookEvent.neighborhood,
                                                                    series.columnDuration / 2))
        let findings = series.events.filter { $0.kind == .finding && $0.overlaps(columnRange) }
            .map { findingEntry($0, format: format, liveness: liveness) }
        let changes = series.events.filter { event in
            event.kind != .finding && event.overlaps(around)
                && !(WatchbookSystemEvent.Kind(rawValue: event.type).map(Self.unmarkedSystemEvents.contains) ?? false)
        }.map { changeEntry($0, format: format) }
        var cpu: [MomentConsumer] = [], memory: [MomentConsumer] = [], note: String?
        switch consumers {
        case .loading:
            note = String(localized: "Verbraucher werden gelesen …")
        case .loaded(nil):
            note = String(localized: "Für diesen Zeitpunkt sind keine Verbraucher aufgezeichnet.")
        case .loaded(let recorded?):
            cpu = recorded.cpu.enumerated().map { index, consumer in
                Self.consumer(consumer, index: index, value: PerformancePresentation.percent(consumer.value),
                              fraction: consumer.value)
            }
            memory = recorded.memory.enumerated().map { index, consumer in
                Self.consumer(consumer, index: index,
                              value: ProcessCleanupPresentation.memoryText(UInt64(max(consumer.value, 0))),
                              fraction: physicalMemory > 0 ? consumer.value / physicalMemory : 0)
            }
        }
        return Moment(time: format.weekdayTime(time), values: values(of: series, at: column), cpuConsumers: cpu,
                      memoryConsumers: memory, consumersNote: note, findings: findings, changes: changes)
    }

    /// Was die Spuren nicht zeigen, nur Gemessenes.
    private func values(of series: WatchbookSeries, at column: Int) -> [MomentValue] {
        func statistic(_ metric: WatchbookMetric) -> WatchbookStatistic? { series.statistics(of: metric)[column] }
        var values: [MomentValue] = []
        func add(_ title: String, _ value: String?) {
            if let value { values.append(MomentValue(title: title, value: value)) }
        }
        add(String(localized: "GPU"), statistic(.gpu).map { PerformancePresentation.percent($0.mean) })
        add(String(localized: "Speicherdruck"), statistic(.memoryPressure).map { statistic in
            let level = Int(statistic.maximum.rounded())
            return ProcessCleanupPresentation.pressureText(level >= 2 ? .critical : level == 1 ? .warning : .normal)
        })
        add(String(localized: "Swap"), statistic(.swapUsed).map {
            ProcessCleanupPresentation.memoryText(UInt64(max($0.mean, 0)))
        })
        add(String(localized: "Thermik"), statistic(.thermalState).map { Self.thermalText(Int($0.maximum.rounded())) })
        add(String(localized: "Akku"), statistic(.batteryCharge).map { charge in
            let source = statistic(.externalPower).map { $0.mean >= 0.5 ? String(localized: "Netzteil")
                : String(localized: "Akku") }
            return [PerformancePresentation.percent(charge.mean), source].compactMap { $0 }.joined(separator: " · ")
        })
        add(String(localized: "Leistung"), statistic(.power).map { PerformancePresentation.watts($0.mean * 1_000) })
        return values
    }

    private func findingEntry(_ event: WatchbookEvent, format: WatchbookTimeFormat,
                              liveness: (ProcessKey) -> ProcessLiveness) -> MomentEntry {
        let time = event.end.map { String(localized: "\(format.time(event.start)) bis \(format.time($0))") }
            ?? String(localized: "seit \(format.time(event.start))")
        let isCritical = event.tone == .critical
        let title = Self.findingKindTitle(event) + (isCritical ? String(localized: ", kritisch") : "")
        return MomentEntry(id: event.id, style: isCritical ? .critical : .finding, source: nil, title: title, time: time, detail: event.summary,
                           jump: Self.findingJump(event, liveness: liveness))
    }

    private func changeEntry(_ event: WatchbookEvent, format: WatchbookTimeFormat) -> MomentEntry {
        if let source = WatchbookChangeSource(event: event) {
            let parts = event.summary.split(separator: ": ", maxSplits: 1).map(String.init)
            return MomentEntry(id: event.id, style: .change, source: .change(source), title: parts[0],
                               time: format.time(event.start), detail: parts.count > 1 ? parts[1] : "",
                               jump: Self.changeJump(source, id: event.id))
        }
        let kind = WatchbookSystemEvent.Kind(rawValue: event.type)
        return MomentEntry(id: event.id, style: .system, source: kind.map(MarkSource.system),
                           title: kind.map(Self.systemTitle) ?? String(localized: "Systemereignis"),
                           time: format.time(event.start), detail: event.summary, jump: nil)
    }

    // MARK: Sprünge

    /// Prozesslast nach Details (nur mit passender PID und Startzeit), neue Dienste nach Verbindungen, auffällige
    /// Erweiterungen nach Erweiterungen; alle übrigen ohne Sprung.
    static func findingJump(_ event: WatchbookEvent, liveness: (ProcessKey) -> ProcessLiveness) -> Jump? {
        if let key = event.process {
            let name = name(of: event.subject) ?? String(localized: "Der Prozess")
            let note: String? = switch liveness(key) {
            case .running(let startTime) where startTime == key.startTime: nil
            case .running, .absent: String(localized: "\(name) läuft nicht mehr.")
            case .unknown: String(localized: "Ob \(name) noch läuft, lässt sich nicht feststellen.")
            }
            return Jump(target: .process(key), title: String(localized: "In Details zeigen"), note: note)
        }
        switch SystemFinding.Kind(rawValue: event.type) {
        case .exposedService:
            return Jump(target: .networkConnections, title: String(localized: "In Verbindungen zeigen"), note: nil)
        case .extensionRisk:
            return Jump(target: .extensions, title: String(localized: "In Erweiterungen zeigen"), note: nil)
        default:
            return nil
        }
    }

    static func changeJump(_ source: WatchbookChangeSource, id: UUID) -> Jump {
        switch source {
        case .autostart:
            Jump(target: .autostart, title: String(localized: "In Autostart zeigen"), note: nil)
        case .networkService:
            Jump(target: .networkConnections, title: String(localized: "In Verbindungen zeigen"), note: nil)
        case .extensionRecord:
            Jump(target: .extensions, title: String(localized: "In Erweiterungen zeigen"), note: nil)
        case .app, .agent:
            Jump(target: .historyEntry(id), title: String(localized: "Im Verlauf zeigen"), note: nil)
        }
    }

    // MARK: Texte

    private static func consumer(_ consumer: WatchbookConsumer, index: Int, value: String,
                                 fraction: Double) -> MomentConsumer {
        let badge = if case .systemProcess = consumer.subject { String(localized: "System") } else { "" }
        let name = name(of: consumer.subject) ?? otherAccountsName
        return MomentConsumer(id: "\(index)-\(name)", name: name, badge: badge, value: value,
                              fraction: min(max(fraction, 0), 1))
    }

    /// Name des Verursachers; „Andere Konten“ ohne Namen; `nil` ohne Verursacher.
    static func name(of subject: WatchbookSubject?) -> String? {
        guard let subject else { return nil }
        return subject.name ?? otherAccountsName
    }

    private static func findingKindTitle(_ event: WatchbookEvent) -> String {
        SystemFinding.Kind(rawValue: event.type).map(findingTitle) ?? String(localized: "Befund")
    }

    private static func systemTitle(_ kind: WatchbookSystemEvent.Kind) -> String {
        switch kind {
        case .boot: String(localized: "Mac gestartet")
        case .sleep: String(localized: "Ruhezustand")
        case .wake: String(localized: "Aufgewacht")
        case .powerAdapterConnected: String(localized: "Netzteil angeschlossen")
        case .powerAdapterDisconnected: String(localized: "Netzteil getrennt")
        case .lowPowerModeOn: String(localized: "Energiesparmodus an")
        case .lowPowerModeOff: String(localized: "Energiesparmodus aus")
        case .thermalState: String(localized: "Thermik")
        case .memoryPressure: String(localized: "Speicherdruck")
        }
    }

    /// „9 min“, „1 h 30 min“, „2 Tage 3 h“.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 1)
        if minutes < 60 { return String(localized: "\(minutes) min") }
        if minutes < 48 * 60 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(rest) min")
        }
        let hours = minutes / 60
        let days = hours / 24, rest = hours % 24
        let dayText = days == 1 ? String(localized: "1 Tag") : String(localized: "\(days) Tage")
        return rest == 0 ? dayText : "\(dayText) \(rest) h"
    }
}
