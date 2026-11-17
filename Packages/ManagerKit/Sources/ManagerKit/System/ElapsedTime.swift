import Foundation

/// Sekunden seit dem Anlegen, gemessen auf `clock` – monoton und unabhängig von der Wanduhr. Mit `ContinuousClock` läuft
/// die Zeit im Ruhezustand des Macs weiter. Für Prüfalter und Fristen der verteilten Komplettprüfung (#649): Ein Rück-
/// oder Vorsprung der Systemzeit verschiebt sie nicht.
struct ElapsedTime: Sendable {
    private let read: @Sendable () -> Duration

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        read = { origin.duration(to: clock.now) }
    }

    var seconds: TimeInterval {
        let components = read().components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Als Datum auf einer eigenen, monotonen Zeitachse (nur untereinander vergleichbar, nicht mit der Wanduhr).
    var date: Date { Date(timeIntervalSinceReferenceDate: seconds) }
}
