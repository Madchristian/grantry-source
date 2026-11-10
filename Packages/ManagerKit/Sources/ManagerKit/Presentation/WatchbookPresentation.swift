import Foundation

/// Darstellung des Tabs „Wachbuch“ (TM-12.5, Spec 2026-11-08 § 5.1): Urteil über den gewählten Zeitraum, Verlaufsspuren
/// aus der verdichteten Reihe (`WatchbookSeries`), Marken der Ereignisleiste, Thermikband, Uhrzeit-Achse und die Werte
/// unter der Zeitmarke. Rein und ohne Uhr: „jetzt“ ist das Ende der Reihe; Kalender und Zeitzone kommen vom Aufrufer.
public struct WatchbookPresentation: Sendable {
    public enum State: Equatable, Sendable {
        /// „Wachbuch führen“ ist aus.
        case off
        /// Die Reihe wird noch gelesen.
        case loading
        /// An, aber im Zeitraum nichts aufgezeichnet.
        case empty
        case recorded
    }

    /// Urteil der Zustandszeile.
    public struct Status: Equatable, Sendable {
        public let title: String
        public let hasFinding: Bool
        public let items: [SystemVerdict.Item]
        public let facts: String
    }

    /// Eine Verlaufsspur: CPU und Arbeitsspeicher als Linie (`lower` leer), Netz und Datenträger als Spiegel.
    public struct Lane: Equatable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            case cpu, memory, network, disk
        }

        /// Obergrenze der Skala: Anteil (0…1), feste Größe (Arbeitsspeicher des Macs) oder Rate nach den Werten.
        public enum Scale: Equatable, Sendable {
            case fraction
            case total(Double)
            case rate
        }

        public let kind: Kind
        public let title: String
        public let upper: [WatchbookStatistic?]
        public let lower: [WatchbookStatistic?]?
        public let scale: Scale

        public var id: Kind { kind }
    }

    /// Woher eine neutrale Marke stammt; die Oberfläche wählt danach das Symbol.
    public enum MarkSource: Hashable, Sendable {
        case change(WatchbookChangeSource)
        case system(WatchbookSystemEvent.Kind)
    }

    /// Eine Marke der Ereignisleiste; `start` und `end` als Anteil am Zeitraum.
    public struct Mark: Equatable, Sendable, Identifiable {
        public enum Style: Hashable, Sendable {
            case finding, critical, change, system
        }

        public let id: UUID
        public let style: Style
        public let start: Double
        public let end: Double
        public let source: MarkSource?
        /// Art, Zeit und Grund in einem Satz (VoiceOver, Ereignisliste).
        public let text: String
    }

    public struct AxisTick: Equatable, Sendable {
        public let position: Double
        public let label: String
    }

    /// Werte einer Spalte in der Reihenfolge von `lanes`, Thermik und Zeitpunkt.
    public struct Readout: Equatable, Sendable {
        public let time: String
        public let laneValues: [String]
        public let thermal: String
    }

    /// Systemereignisse ohne Marke: Thermik zeigt das Band, Speicherdruck die Spur.
    static let unmarkedSystemEvents: Set<WatchbookSystemEvent.Kind> = [.thermalState, .memoryPressure]
    /// Abstand der Achsenbeschriftung zu „jetzt“ am rechten Rand und zum linken Rand.
    static let axisMarginEnd = 0.06
    static let axisMarginStart = 0.02
    /// Höchstens so viele Chips (Standard § 3.1).
    static let maximumItems = 3

    public let state: State
    public let status: Status
    public let lanes: [Lane]
    public let marks: [Mark]
    /// Ton je Spalte: normal `neutral` (Bahn ohne Farbe), mäßig und ernst `warning`, kritisch `critical`; `nil` =
    /// nicht gemessen.
    public let thermal: [PresentationTone?]
    public let axis: [AxisTick]
    /// Spalten je Pfeiltaste.
    public let markerStep: Int
    /// „2 Befunde · 1 Änderung“.
    public let eventSummary: String
    /// Detailzeile im Peilkopf.
    public let detail: String

    let series: WatchbookSeries?
    let thermalLevels: [Int?]
    let calendar: Calendar
    let period: WatchbookPeriod
    let physicalMemory: Double

    /// - Parameters:
    ///   - series: verdichtete Reihe des Zeitraums; `nil`, solange sie gelesen wird.
    ///   - recordingSince: seit wann das Wachbuch an ist; `nil`, wenn unbekannt.
    ///   - physicalMemory: Arbeitsspeicher des Macs in Byte (Skala der Spur).
    public init(series: WatchbookSeries?, period: WatchbookPeriod, isEnabled: Bool, recordingSince: Date?,
                physicalMemory: Double, calendar: Calendar = .current) {
        self.series = series
        self.calendar = calendar
        self.period = period
        self.physicalMemory = physicalMemory
        let shown = isEnabled ? series : nil
        let format = WatchbookTimeFormat(calendar: calendar)
        let marks = shown.map { series in
            series.events.sorted { $0.start < $1.start }.compactMap { Self.mark(for: $0, in: series, format: format) }
        } ?? []
        let isRecorded = shown.map { series in
            !marks.isEmpty || WatchbookMetric.allCases.contains { series.statistics(of: $0).contains { $0 != nil } }
        } ?? false
        let state: State = !isEnabled ? .off : series == nil ? .loading : isRecorded ? .recorded : .empty
        self.marks = marks
        self.state = state
        lanes = shown.map { Self.lanes(of: $0, physicalMemory: physicalMemory) } ?? []
        thermalLevels = shown.map { $0.statistics(of: .thermalState).map { $0.map { Int($0.maximum.rounded()) } } } ?? []
        thermal = thermalLevels.map { $0.map(Self.tone(ofThermalLevel:)) }
        axis = shown.map { Self.axis(for: $0.range, period: period, calendar: calendar) } ?? []
        markerStep = shown.map { max(Int((period.markerStep / $0.columnDuration).rounded()), 1) } ?? 1
        eventSummary = Self.eventSummary(marks)
        detail = "\(period.recentTitle) · " + (state == .recorded
            ? String(localized: "Zeitmarke per Klick, Ziehen oder Pfeiltasten")
            : String(localized: "gemeinsame Zeitachse"))
        status = Self.status(state: state, series: shown, marks: marks, period: period,
                             recordingSince: recordingSince, format: format)
    }

    /// Werte unter der Zeitmarke; ohne Zeitmarke die neueste Spalte mit Messung und als Zeit „jetzt“.
    public func readout(at column: Int?) -> Readout {
        let index = column ?? newestMeasuredColumn
        let time = column.flatMap { column in
            series.map { WatchbookTimeFormat(calendar: calendar).weekdayTime($0.time(ofColumn: column)) }
        } ?? String(localized: "jetzt")
        guard let index else {
            return Readout(time: time, laneValues: lanes.map { _ in PerformancePresentation.missing },
                           thermal: Self.thermalText(nil))
        }
        return Readout(time: time, laneValues: lanes.map { $0.value(at: index) },
                       thermal: Self.thermalText(thermalLevels.indices.contains(index) ? thermalLevels[index] : nil))
    }

    private var newestMeasuredColumn: Int? {
        lanes.lazy.compactMap { $0.upper.lastIndex { $0 != nil } }.max()
    }

    // MARK: Spuren

    private static func lanes(of series: WatchbookSeries, physicalMemory: Double) -> [Lane] {
        [
            Lane(kind: .cpu, title: String(localized: "CPU"), upper: series.statistics(of: .cpuTotal), lower: nil,
                 scale: .fraction),
            Lane(kind: .memory, title: String(localized: "Arbeitsspeicher"), upper: series.statistics(of: .memoryUsed),
                 lower: nil, scale: .total(physicalMemory)),
            Lane(kind: .network, title: String(localized: "Netz"), upper: series.statistics(of: .networkReceived),
                 lower: series.statistics(of: .networkSent), scale: .rate),
            Lane(kind: .disk, title: String(localized: "Datenträger"), upper: series.statistics(of: .diskRead),
                 lower: series.statistics(of: .diskWrite), scale: .rate),
        ]
    }

    private static func tone(ofThermalLevel level: Int) -> PresentationTone {
        switch level {
        case ...0: .neutral
        case 1, 2: .warning
        default: .critical
        }
    }

    /// Wie `SystemVerdictPresentation` die Stufen von `ProcessInfo.ThermalState` nennt.
    static func thermalText(_ level: Int?) -> String {
        switch level {
        case nil: String(localized: "nicht gemessen")
        case .some(...0): String(localized: "normal")
        case 1: String(localized: "mäßig")
        case 2: String(localized: "ernst")
        default: String(localized: "kritisch")
        }
    }

    // MARK: Marken

    private static func mark(for event: WatchbookEvent, in series: WatchbookSeries,
                             format: WatchbookTimeFormat) -> Mark? {
        let start = series.share(of: event.start), end = event.end.map(series.share) ?? 1
        switch event.kind {
        case .finding:
            let critical = event.tone == .critical
            var title = SystemFinding.Kind(rawValue: event.type).map(findingTitle) ?? String(localized: "Befund")
            if critical { title += String(localized: ", kritisch") }
            let when = event.end.map { String(localized: "\(format.time(event.start)) bis \(format.time($0))") }
                ?? String(localized: "seit \(format.time(event.start)), läuft")
            return Mark(id: event.id, style: critical ? .critical : .finding, start: start, end: end, source: nil,
                        text: String(localized: "Befund \(title), \(when): \(event.summary)"))
        case .change:
            return Mark(id: event.id, style: .change, start: start, end: start,
                        source: WatchbookChangeSource(event: event).map(MarkSource.change),
                        text: String(localized: "Änderung um \(format.time(event.start)): \(event.summary)"))
        case .system:
            let kind = WatchbookSystemEvent.Kind(rawValue: event.type)
            if let kind, unmarkedSystemEvents.contains(kind) { return nil }
            let when = if let end = event.end, end > event.start {
                String(localized: "von \(format.time(event.start)) bis \(format.time(end))")
            } else {
                String(localized: "um \(format.time(event.start))")
            }
            return Mark(id: event.id, style: .system, start: start, end: max(end, start),
                        source: kind.map(MarkSource.system),
                        text: String(localized: "Systemereignis \(when): \(event.summary)"))
        }
    }

    /// Kurzer Name einer Befundart für Chips und Marken.
    static func findingTitle(_ kind: SystemFinding.Kind) -> String {
        switch kind {
        case .systemLoad: String(localized: "Dauerlast")
        case .processLoad: String(localized: "Prozesslast")
        case .memoryPressure: String(localized: "Speicherdruck")
        case .swapGrowth: String(localized: "Auslagerung")
        case .thermalState: String(localized: "Thermik")
        case .throttling: String(localized: "Drosselung")
        case .diskLoad: String(localized: "Datenträgerlast")
        case .sustainedUpload: String(localized: "Upload")
        case .batteryDrain: String(localized: "Akkuentladung")
        case .exposedService: String(localized: "Neuer Dienst")
        case .extensionRisk: String(localized: "Erweiterung")
        case .volumeFull: String(localized: "Volume fast voll")
        case .smartFailure: String(localized: "SMART-Fehler")
        case .staleSnapshots: String(localized: "Alte Snapshots")
        }
    }

    private static func eventSummary(_ marks: [Mark]) -> String {
        let findings = marks.count { $0.style == .finding || $0.style == .critical }
        let changes = marks.count { $0.style == .change }
        guard findings + changes > 0 else { return String(localized: "Keine Befunde, keine Änderungen") }
        return "\(findingCount(findings)) · \(changeCount(changes))"
    }

    private static func findingCount(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "Keine Befunde")
        case 1: String(localized: "1 Befund")
        default: String(localized: "\(count) Befunde")
        }
    }

    private static func changeCount(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "keine Änderungen")
        case 1: String(localized: "1 Änderung")
        default: String(localized: "\(count) Änderungen")
        }
    }

    // MARK: Urteil

    private static func status(state: State, series: WatchbookSeries?, marks: [Mark], period: WatchbookPeriod,
                               recordingSince: Date?, format: WatchbookTimeFormat) -> Status {
        switch state {
        case .off:
            return Status(title: String(localized: "Wachbuch ist aus"), hasFinding: false, items: [],
                          facts: String(localized: "Aufzeichnung aus"))
        case .loading, .empty:
            return Status(title: String(localized: "Noch keine Aufzeichnung"), hasFinding: false, items: [],
                          facts: facts(series: series, recordingSince: recordingSince, format: format))
        case .recorded:
            break
        }
        let findings = marks.filter { $0.style == .finding || $0.style == .critical }
        let ongoing = series?.events.count { $0.kind == .finding && $0.end == nil } ?? 0
        var title: String
        if findings.isEmpty {
            title = String(localized: "Ruhig seit \(quietDuration(series, period: period))")
        } else {
            title = "\(findingCount(findings.count)) \(period.withinTitle)"
            if ongoing > 0 {
                title += " · " + (ongoing == 1 ? String(localized: "1 läuft") : String(localized: "\(ongoing) laufen"))
            }
        }
        return Status(title: title, hasFinding: !findings.isEmpty, items: items(series: series, marks: marks),
                      facts: facts(series: series, recordingSince: recordingSince, format: format))
    }

    /// Kritische zuerst als Zahl, dann die Befundarten nach Häufigkeit (bei Gleichstand die frühere), mit Platz die
    /// Änderungen.
    private static func items(series: WatchbookSeries?, marks: [Mark]) -> [SystemVerdict.Item] {
        let events = (series?.events ?? []).filter { $0.kind == .finding }
        var items: [SystemVerdict.Item] = []
        let critical = events.count { $0.tone == .critical }
        if critical > 0 {
            items.append(SystemVerdict.Item(text: String(localized: "\(critical) kritisch"), tone: .critical))
        }
        var counts: [String: (count: Int, first: Date)] = [:]
        for event in events where event.tone != .critical {
            let title = SystemFinding.Kind(rawValue: event.type).map(findingTitle) ?? String(localized: "Befund")
            let known = counts[title]
            counts[title] = ((known?.count ?? 0) + 1, min(known?.first ?? event.start, event.start))
        }
        let kinds = counts.sorted { ($1.value.count, $0.value.first) < ($0.value.count, $1.value.first) }
        items += kinds.map { SystemVerdict.Item(text: $0.key, tone: .warning) }
        let changes = marks.count { $0.style == .change }
        if changes > 0, items.count < maximumItems {
            items.append(SystemVerdict.Item(text: changeCount(changes), tone: .neutral))
        }
        return Array(items.prefix(maximumItems))
    }

    private static func facts(series: WatchbookSeries?, recordingSince: Date?, format: WatchbookTimeFormat) -> String {
        var facts = recordingSince.map { since in
            let now = series?.range.upperBound ?? since
            let text = format.calendar.isDate(since, inSameDayAs: now) ? format.time(since) : format.dateTime(since)
            return String(localized: "Aufzeichnung an seit \(text)")
        } ?? String(localized: "Aufzeichnung an")
        let problems = series?.problems.count ?? 0
        if problems > 0 {
            facts += " · " + (problems == 1 ? String(localized: "1 Datei nicht lesbar")
                : String(localized: "\(problems) Dateien nicht lesbar"))
        }
        return facts
    }

    /// Seit Beginn der Messung im Zeitraum – höchstens der ganze Zeitraum.
    private static func quietDuration(_ series: WatchbookSeries?, period: WatchbookPeriod) -> String {
        guard let series else { return period.durationTitle }
        let first = WatchbookMetric.allCases.compactMap { series.statistics(of: $0).firstIndex { $0 != nil } }.min() ?? 0
        let seconds = series.range.upperBound.timeIntervalSince(series.time(ofColumn: first))
            + series.columnDuration / 2
        return durationText(min(seconds, period.duration))
    }

    /// „1 Minute“, „25 Minuten“, „5 Stunden“, „7 Tagen“ – im Dativ nach „seit“.
    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 1)
        if minutes < 60 { return minutes == 1 ? String(localized: "1 Minute") : String(localized: "\(minutes) Minuten") }
        let hours = Int((seconds / 3_600).rounded())
        if hours < 48 { return hours == 1 ? String(localized: "1 Stunde") : String(localized: "\(hours) Stunden") }
        let days = Int((seconds / 86_400).rounded())
        return days == 1 ? String(localized: "1 Tag") : String(localized: "\(days) Tagen")
    }

    // MARK: Zeitachse

    /// Beschriftung an vollen Viertelstunden, Stunden, drei Stunden bzw. Mitternacht; Mitternacht nennt den Wochentag.
    private static func axis(for range: Range<Date>, period: WatchbookPeriod, calendar: Calendar) -> [AxisTick] {
        let format = WatchbookTimeFormat(calendar: calendar)
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        var ticks: [AxisTick] = []
        var time = calendar.startOfDay(for: range.lowerBound)
        while time < range.upperBound {
            let position = time.timeIntervalSince(range.lowerBound) / duration
            if position >= axisMarginStart, position <= 1 - axisMarginEnd {
                let isMidnight = calendar.startOfDay(for: time) == time
                ticks.append(AxisTick(position: position, label: isMidnight ? format.weekday(time) : format.time(time)))
            }
            guard let next = calendar.date(byAdding: period.axisStep, to: time) else { break }
            time = next
        }
        return ticks + [AxisTick(position: 1, label: String(localized: "jetzt"))]
    }
}

extension WatchbookPeriod {
    /// „Letzte 24 Stunden“ für den Peilkopf.
    var recentTitle: String {
        switch self {
        case .hour: String(localized: "Letzte Stunde")
        case .sixHours: String(localized: "Letzte 6 Stunden")
        case .day: String(localized: "Letzte 24 Stunden")
        case .week: String(localized: "Letzte 7 Tage")
        }
    }

    /// „in den letzten 24 Stunden“ hinter der Zahl der Befunde.
    var withinTitle: String {
        switch self {
        case .hour: String(localized: "in der letzten Stunde")
        case .sixHours: String(localized: "in den letzten 6 Stunden")
        case .day: String(localized: "in den letzten 24 Stunden")
        case .week: String(localized: "in den letzten 7 Tagen")
        }
    }

    var durationTitle: String { WatchbookPresentation.durationText(duration) }

    /// Abstand der Achsenbeschriftung.
    var axisStep: DateComponents {
        switch self {
        case .hour: DateComponents(minute: 15)
        case .sixHours: DateComponents(hour: 1)
        case .day: DateComponents(hour: 3)
        case .week: DateComponents(day: 1)
        }
    }

    /// Weg der Zeitmarke je Pfeiltaste.
    var markerStep: TimeInterval {
        switch self {
        case .hour: 60
        case .sixHours: 300
        case .day: 900
        case .week: 3_600
        }
    }
}

extension WatchbookSeries {
    /// Mitte der Spalte `column`.
    public func time(ofColumn column: Int) -> Date {
        range.lowerBound.addingTimeInterval((Double(column) + 0.5) * columnDuration)
    }

    /// Anteil von `date` am Zeitraum, auf 0…1 begrenzt.
    func share(of date: Date) -> Double {
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(range.lowerBound) / duration, 0), 1)
    }
}

extension WatchbookPresentation.Lane {
    /// Mittel der Spalte als Text: Anteil, Speicher oder „↓ empfangen · ↑ gesendet“.
    func value(at column: Int) -> String {
        let mean = { (values: [WatchbookStatistic?]) in values.indices.contains(column) ? values[column]?.mean : nil }
        switch kind {
        case .cpu: return PerformancePresentation.percent(mean(upper))
        case .memory:
            return mean(upper).map { ProcessCleanupPresentation.memoryText(UInt64($0)) } ?? PerformancePresentation.missing
        case .network, .disk:
            let up = mean(upper), down = lower.flatMap(mean)
            guard up != nil || down != nil else { return PerformancePresentation.missing }
            let rate = { (value: Double?) in value.map(TrafficFormat.rate) ?? PerformancePresentation.missing }
            return "↓ \(rate(up)) · ↑ \(rate(down))"
        }
    }
}

/// Uhrzeiten und Wochentage in der Zeitzone des Kalenders.
struct WatchbookTimeFormat: Sendable {
    let calendar: Calendar

    private var locale: Locale { calendar.locale ?? Locale(identifier: "de_DE") }

    private func style(_ base: Date.FormatStyle) -> Date.FormatStyle {
        var style = base
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return style
    }

    /// „09:14“.
    func time(_ date: Date) -> String {
        date.formatted(style(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
    }

    /// „Sa“.
    func weekday(_ date: Date) -> String {
        date.formatted(style(Date.FormatStyle().weekday(.abbreviated)))
    }

    /// „Sa 12:30“.
    func weekdayTime(_ date: Date) -> String { "\(weekday(date)) \(time(date))" }

    /// „Mo. 2. Nov., 13:00“.
    func dateTime(_ date: Date) -> String {
        let day = date.formatted(style(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)))
        return "\(day), \(time(date))"
    }
}
