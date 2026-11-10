import Testing
@testable import ManagerKit

@Suite struct BatterySamplerTests {
    private static var description: [String: Any] { [
        "Type": "InternalBattery", "Is Present": true, "Current Capacity": 80, "Max Capacity": 100,
        "Power Source State": "AC Power", "Is Charging": false, "Is Charged": false, "Time to Empty": 0,
        "Time to Full Charge": 0, "DesignCycleCount": 300,
    ] }
    private static var registry: [String: Any] { [
        "Voltage": 12_395, "InstantAmperage": -346, "Amperage": -346, "CycleCount": 86, "DesignCycleCount9C": 1_000,
        "BatteryData": ["FullChargeCapacity": 6_100, "DesignCapacity": 6_249] as [String: Any],
        "PowerTelemetryData": ["SystemLoad": 88_619, "SystemPowerIn": 84_331] as [String: Any],
    ] }

    /// Wie `IOPSCopyExternalPowerAdapterDetails` an einem USB-C-Netzteil (am 2026-11-08 gelesen, ohne Seriennummer).
    private static var adapter: [String: Any] { [
        "Watts": 100, "Description": "pd charger", "AdapterVoltage": 20_000, "Current": 5_000, "AdapterID": 0,
        "FamilyCode": -536_854_518, "IsWireless": false,
    ] }

    private func reading(_ description: [String: Any] = Self.description, _ registry: [String: Any] = Self.registry,
                         adapter: [String: Any]? = nil) -> BatteryReading? {
        BatterySampler.reading(powerSource: description, battery: registry, adapter: adapter)
    }

    @Test func readsChargeAndPowerSource() throws {
        let reading = try #require(reading())
        #expect(reading.charge == 0.8)
        #expect(reading.source == .externalPower)
        #expect(!reading.isCharging)
        #expect(!reading.isCharged)
    }

    /// Wachbuch-Takt (#530): Ladestand und Stromquelle kommen allein aus der Stromquellen-Beschreibung.
    @Test func chargeAndSourceNeedNoRegistry() throws {
        let reading = try #require(reading(Self.description, [:]))
        #expect(reading.charge == 0.8)
        #expect(reading.source == .externalPower)
        #expect((TaskManagerSources.watchbook.battery == nil) == (TaskManagerSources.system.battery == nil))
    }

    @Test func zeroTimesMeanNotApplicable() throws {
        let reading = try #require(reading())
        #expect(reading.minutesToEmpty == nil)
        #expect(reading.minutesToFull == nil)
    }

    @Test func calculatingTimeIsUnknownAndRealTimeIsKept() throws {
        var description = Self.description
        description["Power Source State"] = "Battery Power"
        description["Time to Empty"] = -1
        #expect(try #require(reading(description)).minutesToEmpty == nil)
        description["Time to Empty"] = 254
        let onBattery = try #require(reading(description))
        #expect(onBattery.minutesToEmpty == 254)
        #expect(onBattery.source == .battery)
    }

    @Test func readsCyclesAndCapacity() throws {
        let reading = try #require(reading())
        #expect(reading.cycleCount == 86)
        #expect(reading.designCycleCount == 1_000)
        let capacity = try #require(reading.maximumCapacity)
        #expect(abs(capacity - 6_100.0 / 6_249) < 1e-12)
        #expect(reading.condition == .normal)
    }

    @Test func batteryPowerIsVoltageTimesCurrent() throws {
        // 12,395 V × −0,346 A = −4,289 W (entlädt trotz Netzteil, Ladeschutz bei 80 %).
        #expect(try #require(reading()).batteryMilliwatts == -4_288.67)
    }

    @Test func systemPowerComesFromTelemetry() throws {
        #expect(try #require(reading()).systemMilliwatts == 88_619)
    }

    @Test func lowCapacityRecommendsService() throws {
        var registry = Self.registry
        registry["BatteryData"] = ["FullChargeCapacity": 4_800, "DesignCapacity": 6_249] as [String: Any]
        #expect(try #require(reading(Self.description, registry)).condition == .serviceRecommended)
    }

    @Test func reportedHealthWins() throws {
        var description = Self.description
        description["BatteryHealth"] = "Poor"
        #expect(try #require(reading(description)).condition == .serviceRecommended)
        description["BatteryHealth"] = "Good"
        var registry = Self.registry
        registry["BatteryData"] = ["FullChargeCapacity": 4_800, "DesignCapacity": 6_249] as [String: Any]
        #expect(try #require(reading(description, registry)).condition == .normal)
    }

    @Test func missingRegistryValuesStayUnknown() throws {
        let reading = try #require(reading(Self.description, [:]))
        #expect(reading.charge == 0.8)
        #expect(reading.cycleCount == nil)
        #expect(reading.maximumCapacity == nil)
        #expect(reading.condition == nil)
        #expect(reading.batteryMilliwatts == nil)
        #expect(reading.systemMilliwatts == nil)
    }

    @Test func readsAdapterOnExternalPower() throws {
        let adapter = try #require(reading(adapter: Self.adapter)?.adapter)
        #expect(adapter == PowerAdapterReading(watts: 100, name: "pd charger"))
    }

    @Test func noAdapterWithoutDetails() throws {
        #expect(try #require(reading()).adapter == nil)
        #expect(try #require(reading(adapter: [:])).adapter == nil)
    }

    @Test func adapterIsNotReadOnBattery() throws {
        var description = Self.description
        description["Power Source State"] = "Battery Power"
        var asked = false
        let reading = BatterySampler.reading(powerSource: description, battery: Self.registry,
                                             adapter: { asked = true; return Self.adapter }())
        #expect(try #require(reading).adapter == nil)
        #expect(!asked)
    }

    @Test func missingAdapterValuesStayUnknown() throws {
        let unnamed = try #require(reading(adapter: ["Watts": 30])?.adapter)
        #expect(unnamed == PowerAdapterReading(watts: 30, name: nil))
        let unrated = try #require(reading(adapter: ["Watts": 0, "Description": "  "])?.adapter)
        #expect(unrated == PowerAdapterReading(watts: nil, name: nil))
    }

    @Test func adapterNameIsOneShortLine() throws {
        let name = "Netz\u{202E}teil\n" + String(repeating: "x", count: 80)
        let adapter = try #require(reading(adapter: ["Description": name])?.adapter)
        let shown = try #require(adapter.name)
        #expect(shown.count == BatterySampler.adapterNameLength)
        #expect(shown.hasPrefix("Netzteil x"))
        #expect(shown.hasSuffix("…"))
    }

    @Test func otherPowerSourcesAreNoBattery() {
        var ups = Self.description
        ups["Type"] = "UPS"
        #expect(reading(ups) == nil)
        var absent = Self.description
        absent["Is Present"] = false
        #expect(reading(absent) == nil)
    }

    @Test func readThrowsWithoutBattery() {
        let sampler = BatterySampler(powerSource: { nil }, registry: { Self.registry })
        #expect(throws: BatterySampler.NotAvailable.self) { try sampler.read() }
    }

    @Test func realBatteryIsPlausibleWhenPresent() throws {
        // Auf Macs ohne Akku (CI: Mac mini) gibt es keine Quelle; dann nichts zu prüfen.
        guard let sampler = BatterySampler.ifAvailable() else { return }
        let reading = try sampler.read()
        let charge = try #require(reading.charge)
        #expect(charge >= 0 && charge <= 1)
        #expect(reading.cycleCount.map { $0 >= 0 } ?? true)
    }

    @Test func systemSourcesMeasureBatteryOnlyWhenPresent() {
        #expect(TaskManagerSources.system.configured.contains(.battery) == (BatterySampler.ifAvailable() != nil))
    }
}
