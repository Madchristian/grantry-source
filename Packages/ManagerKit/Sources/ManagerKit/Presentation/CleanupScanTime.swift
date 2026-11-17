import Foundation

/// Zeit des letzten vollständigen Scans in Aufräumen › Prozesse und Speicher (#611), wie die Suchzeit der App-Reste
/// (`LeftoverSearchStand.timeText`): „Scan 14:32“.
public enum CleanupScanTime {
    /// „Scan 14:32“.
    public static func text(_ date: Date) -> String {
        "Scan \(clockText(date))"
    }

    /// „14:32“.
    public static func clockText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Hängt „ · Scan 14:32“ an, wenn die Zeit bekannt ist.
    static func appending(to text: String, scannedAt: Date?) -> String {
        scannedAt.map { text + " · " + Self.text($0) } ?? text
    }
}
