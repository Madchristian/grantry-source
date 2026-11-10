#if DEBUG
import Foundation

/// Festes Wachbuch für SwiftUI-Previews und den Render-Wächter (TM-12.5): Werte hängen nur vom Zeitpunkt ab, sodass ein
/// späteres Ende dieselben Verläufe weiterschiebt; ein beendeter Befund, ein laufender, eine Änderung und ein Ruhezustand
/// liegen fest vor `now`.
public enum WatchbookPreviewData {
    /// Sonntag, 8. November 2026, 15:40 Uhr in Berlin.
    public static let now = Date(timeIntervalSince1970: 1_794_148_800)
    public static let physicalMemory = 32.0 * 1_073_741_824

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        calendar.locale = Locale(identifier: "de_DE")
        return calendar
    }

    /// Verdichtete Reihe für `period` bis `end` auf `width` Spalten.
    public static func series(_ period: WatchbookPeriod, endingAt end: Date = now, width: Int = 1_000) -> WatchbookSeries {
        let range = end.addingTimeInterval(-period.duration)..<end
        var builder = WatchbookSeriesBuilder(range: range, width: width)
        builder.add(points(in: range))
        return builder.build(events: events.filter { $0.overlaps(range) }, problems: [])
    }

    /// Darstellung wie im Tab, mit Berliner Zeit.
    public static func presentation(_ period: WatchbookPeriod, endingAt end: Date = now, width: Int = 1_000,
                                    isEnabled: Bool = true) -> WatchbookPresentation {
        WatchbookPresentation(series: series(period, endingAt: end, width: width), period: period, isEnabled: isEnabled,
                              recordingSince: now.addingTimeInterval(-6 * 86_400 - 6 * 3_600),
                              physicalMemory: physicalMemory, calendar: calendar)
    }

    /// Ruhezustand in der Nacht vor `now`.
    static let sleep = (start: now.addingTimeInterval(-14.5 * 3_600), end: now.addingTimeInterval(-9 * 3_600))

    static let events: [WatchbookEvent] = [
        WatchbookEvent(id: UUID(stableHashOf: "preview.finding"), kind: .finding,
                       type: SystemFinding.Kind.systemLoad.rawValue, start: now.addingTimeInterval(-38 * 60),
                       end: now.addingTimeInterval(-29 * 60), tone: .finding, subject: nil,
                       summary: "CPU insgesamt länger als 2 min über 80 % ausgelastet."),
        WatchbookEvent(id: UUID(stableHashOf: "preview.ongoing"), kind: .finding,
                       type: SystemFinding.Kind.processLoad.rawValue, start: now.addingTimeInterval(-6 * 60), end: nil,
                       tone: .finding, subject: .program("SourceKitService"),
                       summary: "SourceKitService belegt länger als 5 min mehr als 90 % eines Kerns."),
        WatchbookEvent(id: UUID(stableHashOf: "preview.change"), kind: .change,
                       type: WatchbookChangeSource.app.rawValue, start: now.addingTimeInterval(-42 * 60),
                       end: now.addingTimeInterval(-42 * 60), tone: nil, subject: .program("Xcode"),
                       summary: "App installiert: Xcode 27.1"),
        WatchbookSystemEvent.sleep(from: sleep.start, to: sleep.end),
        WatchbookSystemEvent.wake(at: sleep.end, reason: "lid open"),
    ]

    /// 10-s-Punkte in `range`, ohne den Ruhezustand.
    static func points(in range: Range<Date>) -> [WatchbookPoint] {
        let first = (range.lowerBound.timeIntervalSince1970 / WatchbookPoint.interval).rounded(.up)
        let last = (range.upperBound.timeIntervalSince1970 / WatchbookPoint.interval).rounded(.down)
        guard first <= last else { return [] }
        return stride(from: first, through: last, by: 1).compactMap { step in
            let time = Date(timeIntervalSince1970: step * WatchbookPoint.interval)
            guard !(sleep.start..<sleep.end).contains(time) else { return nil }
            return point(at: time)
        }
    }

    static func point(at time: Date) -> WatchbookPoint {
        let t = time.timeIntervalSince(now)
        func wave(_ period: Double, _ phase: Double = 0) -> Double { 0.5 + 0.5 * sin(t / period + phase) }
        let busy = events.contains { $0.kind == .finding && $0.overlaps(time..<time.addingTimeInterval(1)) }
        var values = WatchbookValues()
        values[.cpuTotal] = busy ? 0.84 + 0.08 * wave(40) : 0.1 + 0.12 * wave(300) + 0.05 * wave(37, 1)
        values[.memoryUsed] = (17 + 2 * wave(5_000) + 0.3 * wave(120, 2)) * 1_073_741_824
        values[.networkReceived] = 150e3 + 400e3 * pow(wave(900, 1), 8)
        values[.networkSent] = 40e3 + 60e3 * wave(700, 3)
        values[.diskRead] = 1e6 + 20e6 * pow(wave(1_100, 2), 12)
        values[.diskWrite] = 0.8e6 + 6e6 * pow(wave(800), 10)
        values[.thermalState] = busy ? 1 : 0
        return WatchbookPoint(time: time, values: values, cpuConsumers: [], memoryConsumers: [])
    }
}
#endif
