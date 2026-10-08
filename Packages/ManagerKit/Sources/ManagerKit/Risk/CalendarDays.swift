import Foundation

/// Alter in Kalendertagen – das gemeinsame Maß von `SecurityPolicy` (Schwellen) und `SecurityCheckPresentation`
/// („heute“, „gestern“, „vor N Tagen“), damit Ampel und angezeigte Tageszahl an den Grenzen übereinstimmen.
public enum CalendarDays {
    /// Ganze Kalendertage von `date` bis `now` (Tagesbeginn zu Tagesbeginn in `calendar`); Daten in der Zukunft
    /// zählen als 0.
    public static func since(_ date: Date, now: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day
        return max(0, days ?? 0)
    }
}
