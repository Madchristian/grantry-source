import CryptoKit
import Foundation
import GrantryShared

/// Systemereignisse des Wachbuchs (Spec 2026-11-08 §5.1): Start des Macs, Ruhezustand bis zum Aufwachen, Aufwachen mit
/// Grund und die Wechsel aus `WatchbookSystemState`. Die Typen sind der maschinenlesbare Teil im Wachbuch und ändern sich
/// daher nicht.
public enum WatchbookSystemEvent {
    public enum Kind: String, CaseIterable, Sendable {
        case boot = "system.boot"
        case sleep = "system.sleep"
        case wake = "system.wake"
        case powerAdapterConnected = "system.power-adapter-on"
        case powerAdapterDisconnected = "system.power-adapter-off"
        case thermalState = "system.thermal-state"
        case memoryPressure = "system.memory-pressure"
        case lowPowerModeOn = "system.low-power-on"
        case lowPowerModeOff = "system.low-power-off"
    }

    /// Längster übernommener Aufwachgrund (`kern.wakereason`).
    static let maximumReasonLength = 80

    /// Start laut `kern.boottime`. Die ID folgt aus dem Zeitpunkt: Bei jedem App-Start erneut eingetragen, ersetzt der
    /// Eintrag nur sich selbst.
    public static func boot(at date: Date) -> WatchbookEvent {
        event(.boot, from: date, to: date, summary: "Mac gestartet.",
              id: UUID(stableHashOf: "\(Kind.boot.rawValue)|\(date.timeIntervalSince1970)"))
    }

    /// Ruhezustand als Zeitraum; Messwerte fehlen darin (Lücke).
    public static func sleep(from start: Date, to end: Date) -> WatchbookEvent {
        event(.sleep, from: start, to: max(start, end), summary: "Ruhezustand.")
    }

    /// Aufwachen; `reason` ist der Rohtext von macOS (`kern.wakereason`), einzeilig und begrenzt übernommen.
    public static func wake(at date: Date, reason: String?) -> WatchbookEvent {
        let reason = reason.map { String(DisplayText.singleLine($0).prefix(maximumReasonLength)) } ?? ""
        return event(.wake, from: date, to: date,
                     summary: reason.isEmpty ? "Aufgewacht." : "Aufgewacht, Grund laut macOS: \(reason).")
    }

    static func event(_ kind: Kind, from start: Date, to end: Date, summary: String,
                      id: UUID = UUID()) -> WatchbookEvent {
        WatchbookEvent(id: id, kind: .system, type: kind.rawValue, start: start, end: end, tone: nil, subject: nil,
                       summary: summary)
    }
}

/// Zustände, deren Wechsel das Wachbuch als Systemereignis führt: Stromquelle, thermischer Zustand, Speicherdruck (als
/// Stufen wie in `WatchbookMetric`) und Energiesparmodus. `nil` heißt „nicht gemessen“ und ist kein Wechsel.
struct WatchbookSystemState: Equatable {
    var externalPower: Double?
    var thermalState: Double?
    var memoryPressure: Double?
    var isLowPowerModeEnabled: Bool?

    init() {}

    init(point: WatchbookPoint, isLowPowerModeEnabled: Bool?) {
        externalPower = point.values[.externalPower]
        thermalState = point.values[.thermalState]
        memoryPressure = point.values[.memoryPressure]
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// Dieser Zustand, wo er nicht gemessen ist, mit den Werten von `previous` – Vergleichsbasis für den nächsten.
    func merged(over previous: WatchbookSystemState) -> WatchbookSystemState {
        var merged = self
        merged.externalPower = externalPower ?? previous.externalPower
        merged.thermalState = thermalState ?? previous.thermalState
        merged.memoryPressure = memoryPressure ?? previous.memoryPressure
        merged.isLowPowerModeEnabled = isLowPowerModeEnabled ?? previous.isLowPowerModeEnabled
        return merged
    }

    /// Wechsel seit `previous` als Ereignisse zum Zeitpunkt `time`; nur zwischen zwei bekannten Werten.
    func changes(since previous: WatchbookSystemState, at time: Date) -> [WatchbookEvent] {
        var events: [WatchbookEvent] = []
        func add(_ kind: WatchbookSystemEvent.Kind, _ summary: String) {
            events.append(WatchbookSystemEvent.event(kind, from: time, to: time, summary: summary))
        }
        if let now = externalPower, let before = previous.externalPower, now != before {
            if now == 1 {
                add(.powerAdapterConnected, "Netzteil angeschlossen.")
            } else {
                add(.powerAdapterDisconnected, "Netzteil getrennt – der Mac läuft auf Akku.")
            }
        }
        if let now = thermalState, let before = previous.thermalState, now != before {
            add(.thermalState, "Thermischer Zustand jetzt \(Self.thermalName(now)).")
        }
        if let now = memoryPressure, let before = previous.memoryPressure, now != before {
            add(.memoryPressure, "Speicherdruck jetzt \(Self.pressureName(now)).")
        }
        if let now = isLowPowerModeEnabled, let before = previous.isLowPowerModeEnabled, now != before {
            if now {
                add(.lowPowerModeOn, "Energiesparmodus eingeschaltet.")
            } else {
                add(.lowPowerModeOff, "Energiesparmodus ausgeschaltet.")
            }
        }
        return events
    }

    /// Stufen wie `WatchbookMetric.thermalState` (`ProcessInfo.ThermalState`).
    private static func thermalName(_ level: Double) -> String {
        switch level {
        case 0: "normal"
        case 1: "erhöht"
        case 2: "ernst"
        default: "kritisch"
        }
    }

    /// Stufen wie `WatchbookMetric.memoryPressure`.
    private static func pressureName(_ level: Double) -> String {
        switch level {
        case 0: "normal"
        case 1: "erhöht"
        default: "kritisch"
        }
    }
}

extension UUID {
    /// Aus den ersten 16 Byte des SHA-256 von `text`: gleicher Text, gleiche ID – über App-Starts hinweg.
    init(stableHashOf text: String) {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        self.init(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
                         bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
