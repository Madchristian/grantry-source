import Darwin
import Foundation

/// Laufzeit seit dem Start des Macs aus `kern.boottime`, einschließlich Ruhezustand – wie `uptime`.
/// `ProcessInfo.systemUptime` zählt nur die Wachzeit (Bewertung 2026.11.7-1188, Mangel 6).
public enum SystemUptime {
    /// Sekunden seit dem Start; ist `kern.boottime` nicht lesbar, die Wachzeit.
    public static func sinceBoot(now: Date = Date()) -> TimeInterval {
        sinceBoot(now: now, boot: bootTime(), awake: ProcessInfo.processInfo.systemUptime)
    }

    /// Wie `sinceBoot(now:)` mit gegebenem Start (`nil`: nicht lesbar) und gegebener Wachzeit.
    static func sinceBoot(now: Date, boot: timeval?, awake: TimeInterval) -> TimeInterval {
        guard let boot else { return awake }
        return seconds(sinceBoot: boot, now: now)
    }

    /// Start des Macs laut `kern.boottime`; `nil`, wenn nicht lesbar.
    public static func bootTime() -> timeval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return boot
    }

    /// Nie negativ, auch wenn die Uhr nach dem Start zurückgestellt wurde.
    static func seconds(sinceBoot boot: timeval, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince1970 - date(boot).timeIntervalSince1970)
    }

    static func date(_ boot: timeval) -> Date {
        Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}
