#if DEBUG
import Foundation

/// Fester App-Verlauf für SwiftUI-Previews und Sichtprüfungen – 30 Tage, gemessen werktags 9–18 Uhr (Task-Manager
/// offen), heute bis 15 Uhr; Wochenenden ohne Messung.
public enum AppUsagePreviewData {
    /// Freitag, 6. November 2026, 15:30 Uhr in Berlin.
    public static let now = Date(timeIntervalSince1970: 1_793_975_400)

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }

    public static let history = makeHistory()

    /// Gegenstand und Verbrauch je voll gemessener Stunde: CPU-Sekunden, Joule, Netz- und Datenträger-Bytes.
    private static let subjects: [(AppUsageSubject, AppUsageTotals)] = [
        (app("com.apple.dt.Xcode", "Xcode", "/Applications/Xcode.app"), totals(900, 2_600, 20e6, 900e6)),
        (app("com.apple.Safari", "Safari", "/Applications/Safari.app"), totals(420, 1_500, 350e6, 120e6)),
        (program("claude"), totals(1_300, 3_900, 80e6, 60e6)),
        (program("codex"), totals(380, 1_100, 25e6, 20e6)),
        (program("node"), totals(640, 1_800, 12e6, 300e6)),
        (app("com.apple.mail", "Mail", "/System/Applications/Mail.app"), totals(35, 90, 18e6, 8e6)),
        (app("com.apple.Music", "Musik", "/System/Applications/Music.app"), totals(60, 400, 140e6, 2e6)),
    ]

    static func makeHistory() -> AppUsageHistory {
        let calendar = calendar
        var history = AppUsageHistory()
        let today = calendar.startOfDay(for: now)
        for day in 0..<30 {
            guard let date = calendar.date(byAdding: .day, value: day - 29, to: today),
                  !calendar.isDateInWeekend(date) else { continue }
            for hour in 9..<18 {
                guard let start = calendar.date(byAdding: .hour, value: hour, to: date), start < now else { continue }
                let share = 0.55 + 0.45 * sin(Double(day * 24 + hour) / 5)
                let usage = subjects.enumerated().map { index, entry in
                    let wave = max(0.05, 0.6 + 0.4 * sin(Double(day * 24 + hour) / 3 + Double(index)))
                    return (entry.0, scaled(entry.1, by: share * wave))
                }
                history.add(AppUsageSample(end: start.addingTimeInterval(1_800), seconds: 3_600 * share,
                                           measuresNetwork: hour < 16, usage: usage))
            }
        }
        return history
    }

    private static func app(_ bundleID: String, _ name: String, _ path: String) -> AppUsageSubject {
        AppUsageSubject(kind: .app, bundleID: bundleID, name: name, bundlePath: path)
    }

    private static func program(_ name: String) -> AppUsageSubject {
        AppUsageSubject(kind: .process, bundleID: nil, name: name, bundlePath: nil)
    }

    private static func totals(_ cpu: Double, _ energy: Double, _ network: Double, _ disk: Double) -> AppUsageTotals {
        AppUsageTotals(cpuSeconds: cpu, energyJoules: energy, networkBytes: network, diskBytes: disk)
    }

    private static func scaled(_ totals: AppUsageTotals, by factor: Double) -> AppUsageTotals {
        AppUsageTotals(cpuSeconds: totals.cpuSeconds * factor, energyJoules: totals.energyJoules.map { $0 * factor },
                       networkBytes: totals.networkBytes.map { $0 * factor }, diskBytes: totals.diskBytes * factor)
    }
}
#endif
