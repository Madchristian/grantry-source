import GrantryShared

/// Raten aus zwei kumulativen Stichproben (Spec §3, §5). Gesunkene Zähler (Überlauf, neuer Zähler) und Messungen ohne
/// verstrichene Zeit ergeben `nil` statt einer Scheinspitze.
public enum RateCalculator {
    /// Zuwachs pro Sekunde.
    public static func perSecond(from previous: UInt64, to current: UInt64, over elapsed: Duration) -> Double? {
        let seconds = elapsed.seconds
        guard seconds > 0, current >= previous else { return nil }
        return Double(current - previous) / seconds
    }

    /// Anteil der Busy-Ticks eines Kerns (0…1).
    public static func load(from previous: CoreTicks, to current: CoreTicks) -> Double? {
        guard current.busy >= previous.busy, current.idle >= previous.idle else { return nil }
        let busy = current.busy - previous.busy
        let total = busy + (current.idle - previous.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }

    /// Anteil der System-Ticks eines Kerns an allen Ticks (0…1).
    public static func systemShare(from previous: CoreTicks, to current: CoreTicks) -> Double? {
        guard current.system >= previous.system, load(from: previous, to: current) != nil else { return nil }
        let total = (current.busy - previous.busy) + (current.idle - previous.idle)
        return Double(current.system - previous.system) / Double(total)
    }

    /// CPU-Anteil eines Prozesses an allen Kernen (0…1, wie Windows 11).
    public static func processLoad(fromNanoseconds previous: UInt64, to current: UInt64, over elapsed: Duration,
                                   coreCount: Int) -> Double? {
        guard coreCount > 0, let nanosecondsPerSecond = perSecond(from: previous, to: current, over: elapsed) else {
            return nil
        }
        return min(1, nanosecondsPerSecond / 1_000_000_000 / Double(coreCount))
    }
}

extension CoreTicks {
    /// Summe mehrerer Kerne – Grundlage der nach Ticks gewichteten Gesamtauslastung.
    static func sum(_ cores: [CoreTicks]) -> CoreTicks {
        CoreTicks(kind: .unknown, busy: cores.reduce(0) { $0 + $1.busy }, idle: cores.reduce(0) { $0 + $1.idle },
                  system: cores.reduce(0) { $0 + $1.system })
    }
}
