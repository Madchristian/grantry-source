import Foundation
import GrantryShared
import IOKit
import IOKit.ps

/// Akku des Macs (Spec 2026-11-06 §6 Stufe 2): Ladestand, Stromquelle und Restzeit aus `IOPSCopyPowerSourcesInfo`,
/// Zyklen, Kapazität und Leistungen aus der IORegistry (`AppleSmartBattery`) – nur lesend, ohne Root, ohne private
/// API. Die IORegistry-Schlüssel sind nicht dokumentiert; fehlt einer, bleibt sein Feld `nil` („–“). Macs ohne Akku
/// richten die Quelle nicht ein (`ifAvailable()`); die Akku-Anzeigen fehlen dann.
///
/// Leistung am Akku = `Voltage` (mV) × `InstantAmperage` (mA, negativ beim Entladen); Leistungsaufnahme des Macs aus
/// `PowerTelemetryData` → `SystemLoad` (mW, am 2026-11-06 gegengeprüft: `SystemPowerIn` − `BatteryPower`). Zustand:
/// `BatteryHealth`, wenn macOS es liefert (Apple Silicon tut es nicht mehr), sonst „Service empfohlen“ unter 80 %
/// maximaler Kapazität. Am Netzteil zusätzlich dessen Nennleistung und Beschreibung aus
/// `IOPSCopyExternalPowerAdapterDetails` (ohne Seriennummer); die Ladeleistung ist die positive Leistung am Akku.
public struct BatterySampler: MetricSource {
    struct NotAvailable: Error, Equatable {}

    /// Die gelesenen IORegistry-Eigenschaften – einzeln statt aller (die übrigen enthalten große Datenblöcke).
    static let registryKeys = ["Voltage", "InstantAmperage", "Amperage", "CycleCount", "DesignCycleCount9C",
                               "BatteryData", "PowerTelemetryData", "AppleRawMaxCapacity", "DesignCapacity"]
    static let serviceThreshold = 0.8
    /// Höchstlänge der Netzteil-Beschreibung – der Text kommt vom Netzteil.
    static let adapterNameLength = 40

    private let powerSource: @Sendable () -> [String: Any]?
    private let registry: @Sendable () -> [String: Any]?
    private let adapterDetails: @Sendable () -> [String: Any]?

    public init() {
        self.init(powerSource: Self.internalBatteryDescription, registry: Self.smartBatteryProperties,
                  adapter: Self.externalAdapterDetails)
    }

    init(powerSource: @escaping @Sendable () -> [String: Any]?, registry: @escaping @Sendable () -> [String: Any]?,
         adapter: @escaping @Sendable () -> [String: Any]? = { nil }) {
        self.powerSource = powerSource
        self.registry = registry
        adapterDetails = adapter
    }

    /// Die Quelle, wenn jetzt ein eingebauter Akku lesbar ist; sonst `nil`.
    /// Nur Ladestand und Stromquelle aus der Stromquellen-Beschreibung, ohne Akku-Register (`AppleSmartBattery`) und
    /// Netzteil-Details – für den Wachbuch-Takt (TM-12.3), der nur diese beiden Werte führt (#530).
    static func chargeAndSource() -> BatterySampler {
        BatterySampler(powerSource: internalBatteryDescription, registry: { nil })
    }

    public static func ifAvailable() -> BatterySampler? {
        let sampler = BatterySampler()
        return (try? sampler.read()) == nil ? nil : sampler
    }

    public func read() throws -> BatteryReading {
        guard let description = powerSource(),
              let reading = Self.reading(powerSource: description, battery: registry() ?? [:],
                                         adapter: adapterDetails()) else {
            throw NotAvailable()
        }
        return reading
    }

    /// Wertet die Beschreibung der Stromquelle (`IOPSGetPowerSourceDescription`) und die Eigenschaften von
    /// `AppleSmartBattery` aus; `nil`, wenn die Stromquelle kein vorhandener eingebauter Akku ist. Die Angaben des
    /// Netzteils werden nur am Netzteil gelesen.
    static func reading(powerSource description: [String: Any], battery: [String: Any],
                        adapter: @autoclosure () -> [String: Any]? = nil) -> BatteryReading? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool ?? true else { return nil }
        let current = int(description[kIOPSCurrentCapacityKey]), maximum = int(description[kIOPSMaxCapacityKey])
        let charge = current.flatMap { current in
            maximum.flatMap { $0 > 0 ? min(max(Double(current) / Double($0), 0), 1) : nil }
        }
        let data = battery["BatteryData"] as? [String: Any] ?? [:]
        let full = int(data["FullChargeCapacity"]) ?? int(battery["AppleRawMaxCapacity"])
        let design = int(data["DesignCapacity"]) ?? int(battery["DesignCapacity"])
        let capacity = full.flatMap { full in design.flatMap { $0 > 0 ? Double(full) / Double($0) : nil } }
        let voltage = int(battery["Voltage"]), amperage = int(battery["InstantAmperage"] ?? battery["Amperage"])
        let telemetry = battery["PowerTelemetryData"] as? [String: Any]
        let source: PowerSourceState = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            ? .battery : .externalPower
        return BatteryReading(
            charge: charge,
            source: source,
            isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
            isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
            minutesToEmpty: minutes(description[kIOPSTimeToEmptyKey]),
            minutesToFull: minutes(description[kIOPSTimeToFullChargeKey]),
            cycleCount: int(battery["CycleCount"]),
            designCycleCount: int(battery["DesignCycleCount9C"]) ?? int(description["DesignCycleCount"]),
            maximumCapacity: capacity,
            condition: condition(health: description[kIOPSBatteryHealthKey] as? String, maximumCapacity: capacity),
            batteryMilliwatts: voltage.flatMap { voltage in amperage.map { Double(voltage * $0) / 1_000 } },
            systemMilliwatts: telemetry.flatMap { int($0["SystemLoad"]) }.map { Double($0) },
            adapter: source == .externalPower ? adapter().flatMap(Self.adapter) : nil
        )
    }

    /// Nennleistung und Beschreibung aus `IOPSCopyExternalPowerAdapterDetails`; `nil` ohne Angaben.
    static func adapter(_ details: [String: Any]) -> PowerAdapterReading? {
        guard !details.isEmpty else { return nil }
        let name = (details["Description"] as? String)
            .map { DisplayText.singleLine($0, maximumLength: adapterNameLength) }
        return PowerAdapterReading(watts: int(details[kIOPSPowerAdapterWattsKey]).flatMap { $0 > 0 ? $0 : nil },
                                   name: name?.isEmpty == false ? name : nil)
    }

    /// Ganzzahl aus einem IOKit-Wert (`NSNumber`, auch negativ).
    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    /// Minuten > 0; `-1` (rechnet noch) und `0` (trifft nicht zu) ergeben `nil`.
    private static func minutes(_ value: Any?) -> Int? {
        int(value).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func condition(health: String?, maximumCapacity: Double?) -> BatteryCondition? {
        if let health { return health == kIOPSGoodValue ? .normal : .serviceRecommended }
        return maximumCapacity.map { $0 < serviceThreshold ? .serviceRecommended : .normal }
    }

    private static func internalBatteryDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return description
            }
        }
        return nil
    }

    private static func externalAdapterDetails() -> [String: Any]? {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
    }

    private static func smartBatteryProperties() -> [String: Any]? {
        var properties: [String: Any]?
        try? IORegistryReader.forEachService(matching: "AppleSmartBattery") { battery in
            guard properties == nil else { return }
            properties = Dictionary(uniqueKeysWithValues: registryKeys.compactMap { key in
                IORegistryReader.property(key, of: battery).map { (key, $0) }
            })
        }
        return properties
    }
}
