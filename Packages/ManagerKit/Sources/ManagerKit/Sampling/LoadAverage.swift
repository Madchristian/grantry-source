import Darwin

/// Durchschnittslast über 1, 5 und 15 Minuten wie `uptime` (`getloadavg`): Zahl der laufenden und wartenden Threads, nicht
/// auf die Kerne bezogen. Für die Übersicht der Menüleiste (#495), gelesen nur bei offenem Popover.
public struct LoadAverage: Hashable, Sendable {
    public let one: Double
    public let five: Double
    public let fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }

    /// `nil`, wenn macOS keine drei Werte liefert.
    public static func current() -> LoadAverage? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return nil }
        return LoadAverage(one: values[0], five: values[1], fifteen: values[2])
    }
}
