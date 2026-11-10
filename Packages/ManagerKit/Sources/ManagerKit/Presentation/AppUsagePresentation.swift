import Foundation

/// Zeitraum des App-Verlaufs.
public enum AppUsageRange: String, Hashable, Sendable, CaseIterable, Identifiable {
    case today, sevenDays, thirtyDays

    public var id: Self { self }

    public var title: String {
        switch self {
        case .today: "Heute"
        case .sevenDays: "7 Tage"
        case .thirtyDays: "30 Tage"
        }
    }
}

extension AppUsageMetric {
    public var title: String {
        switch self {
        case .cpu: "CPU-Zeit"
        case .energy: "Energie"
        case .network: "Netzwerk"
        case .disk: "Datenträger"
        }
    }

    /// „2 h 14 min“, „3,4 Wh“, „1,5 MB“; „nicht gemessen“ ohne Wert.
    public func text(_ value: Double?) -> String {
        guard let value else { return "nicht gemessen" }
        return switch self {
        case .cpu: AppUsagePresentation.durationText(value)
        case .energy: EnergyFormat.energy(joules: value)
        case .network, .disk: TrafficFormat.bytes(UInt64(max(value, 0).rounded()))
        }
    }

    /// Wie `text(_:)`, für schmale Spalten aber „–“ ohne Wert (wie die Prozessliste).
    public func shortText(_ value: Double?) -> String {
        value == nil ? "–" : text(value)
    }
}

/// Eine App bzw. ein eigenes Programm mit seinem Verbrauch im Zeitraum.
public struct AppUsageRow: Hashable, Sendable, Identifiable {
    public let subject: AppUsageSubject
    public let totals: AppUsageTotals

    public var id: String { subject.id }
}

/// Eine Säule: eine Stunde (Heute) oder ein Tag.
public struct AppUsageBar: Hashable, Sendable, Identifiable {
    public let index: Int
    public let start: Date
    /// Summe der gewählten Kennzahl über alle Apps; `nil`, wenn sie im Abschnitt nicht gemessen wurde.
    public let value: Double?
    public let measuredSeconds: Double
    public let label: String
    public let detail: String

    public var id: Int { index }
    public var isMeasured: Bool { value != nil }
}

public struct AppUsageSummary: Hashable, Sendable {
    public let rows: [AppUsageRow]
    public let totals: AppUsageTotals
    public let bars: [AppUsageBar]
    public let measuredSeconds: Double
    public let networkSeconds: Double

    public var isEmpty: Bool { rows.isEmpty }
}

/// Zeilen, Säulen und Texte des Tabs „App-Verlauf“ (Spec 2026-11-06 §6 Stufe 2). Rein; Zeitraum und Beschriftung nach
/// dem übergebenen Kalender (Zeitzone, Sommerzeit).
public enum AppUsagePresentation {
    public static let scopeNote = "Nur Zeiten, in denen der Task-Manager gemessen hat. Prozesse anderer Benutzer "
        + "werden nicht aufgezeichnet; gespeichert wird lokal und 30 Tage lang."

    private static let weekdays = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]

    public static func summary(of history: AppUsageHistory, range: AppUsageRange, metric: AppUsageMetric, now: Date,
                               calendar: Calendar = .current) -> AppUsageSummary {
        let buckets = buckets(for: range, now: now, calendar: calendar)
        let start = buckets.first?.start ?? now
        let hours = history.hours.filter { $0.start >= start && $0.start <= now }
        var totals: [String: AppUsageTotals] = [:]
        for hour in hours {
            for (id, used) in hour.usage { totals[id, default: .empty] += used }
        }
        let rows = totals.compactMap { id, used in history.subjects[id].map { AppUsageRow(subject: $0, totals: used) } }
            .sorted { lhs, rhs in
                // Nicht Gemessenes zuletzt.
                let left = lhs.totals[metric] ?? -1, right = rhs.totals[metric] ?? -1
                guard left == right else { return left > right }
                return lhs.subject.name.localizedStandardCompare(rhs.subject.name) == .orderedAscending
            }
        let bars = buckets.enumerated().map { index, bucket in
            let inside = hours.filter { $0.start >= bucket.start && $0.start < bucket.end }
            let measuredValues = inside.compactMap { $0.total(metric) }
            let value = measuredValues.isEmpty ? nil : measuredValues.reduce(0, +)
            let labels = labels(for: range, index: index, count: buckets.count, start: bucket.start,
                                calendar: calendar)
            return AppUsageBar(index: index, start: bucket.start, value: value,
                               measuredSeconds: inside.reduce(0) { $0 + $1.measuredSeconds }, label: labels.axis,
                               detail: "\(labels.full): \(metric.text(value))")
        }
        return AppUsageSummary(rows: rows, totals: rows.reduce(.empty) { $0 + $1.totals }, bars: bars,
                               measuredSeconds: hours.reduce(0) { $0 + $1.measuredSeconds },
                               networkSeconds: hours.reduce(0) { $0 + $1.networkSeconds })
    }

    /// „CPU-Zeit je Stunde“, „Energie je Tag“.
    public static func chartTitle(metric: AppUsageMetric, range: AppUsageRange) -> String {
        "\(metric.title) je \(range == .today ? "Stunde" : "Tag")"
    }

    /// „Gemessen: 1 h 10 min“, bei Netz zusätzlich die Zeit, in der nettop lief.
    public static func coverageText(_ summary: AppUsageSummary, metric: AppUsageMetric) -> String {
        guard summary.measuredSeconds > 0 else { return "Noch nicht gemessen" }
        let measured = "Gemessen: \(durationText(summary.measuredSeconds))"
        return metric == .network ? "\(measured) · Netz: \(durationText(summary.networkSeconds))" : measured
    }

    /// „0 s“, „42 s“, „59 min“, „1 h“, „2 h 14 min“.
    public static func durationText(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        guard total >= 60 else { return "\(total) s" }
        let minutes = total / 60
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// Intensität einer Zelle relativ zum größten Wert der Spalte, Wurzelskala wie die Prozessliste; `nil` ohne Wert.
    public static func heat(_ value: Double, maximum: Double) -> Double? {
        guard maximum > 0 else { return nil }
        return min(max(value / maximum, 0), 1).squareRoot()
    }

    /// Abschnitte des Zeitraums: Stunden des heutigen Tags bzw. die letzten 7 oder 30 Tage einschließlich heute.
    private static func buckets(for range: AppUsageRange, now: Date, calendar: Calendar)
        -> [(start: Date, end: Date)] {
        let today = calendar.startOfDay(for: now)
        let (component, count, first): (Calendar.Component, Int, Date) = switch range {
        case .today: (.hour, 24, today)
        case .sevenDays: (.day, 7, calendar.date(byAdding: .day, value: -6, to: today) ?? today)
        case .thirtyDays: (.day, 30, calendar.date(byAdding: .day, value: -29, to: today) ?? today)
        }
        let starts = (0...count).compactMap { calendar.date(byAdding: component, value: $0, to: first) }
        return zip(starts, starts.dropFirst()).map { (start: $0, end: $1) }
    }

    /// Achsenbeschriftung (sparsam) und voller Text eines Abschnitts.
    private static func labels(for range: AppUsageRange, index: Int, count: Int, start: Date, calendar: Calendar)
        -> (axis: String, full: String) {
        let parts = calendar.dateComponents([.hour, .day, .month, .weekday], from: start)
        let weekday = weekdays[((parts.weekday ?? 1) - 1) % 7]
        let date = "\(parts.day ?? 0).\(parts.month ?? 0)."
        switch range {
        case .today:
            let hour = parts.hour ?? index
            return (hour % 6 == 0 ? "\(hour)" : "", "\(hour) Uhr")
        case .sevenDays:
            return (weekday, "\(weekday), \(date)")
        case .thirtyDays:
            return ((count - 1 - index) % 5 == 0 ? date : "", "\(weekday), \(date)")
        }
    }
}
