import Foundation

/// Relative Zeitangaben („vor 5 Minuten“) in der Sprache der Bundle-Lokalisierung (`de`).
enum RelativeTime {
    /// `now` stammt oft aus einem Minutentakt und kann vor `date` liegen – dann „jetzt“ statt „in … s“.
    static func text(for date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: max(now, date))
    }
}
