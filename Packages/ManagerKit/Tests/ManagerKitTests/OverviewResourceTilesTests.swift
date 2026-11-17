import Foundation
import Testing
@testable import ManagerKit

/// Kacheln Arbeitsspeicher, Datenträger, Netz, Thermik, Akku, Durchschnittslast und Laufzeit des Übersichts-Baukastens
/// (Spec 2026-11-09-uebersicht-baukasten § 2, Teil C #502): kurze Werte für 1 × 1, Anteile und Beträge für größere
/// Kacheln, VoiceOver-Werte je Kachel; fehlende Werte „–“, nie 0.
@Suite struct OverviewResourceTilesTests {
    private static let gigabyte: UInt64 = 1 << 30

    private static func overview(_ snapshot: TaskManagerSnapshot = TaskManagerSnapshot(),
                                 context: MenuBarOverviewContext = MenuBarOverviewContext()) -> MenuBarOverview {
        MenuBarOverviewPresentation.overview(for: snapshot, profile: ChipProfile(facts: ChipFacts()), context: context)
    }

    /// Formatter setzen geschützte Leerzeichen vor Einheiten.
    private static func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private static func memory(pressure: MemoryStatus.Pressure? = .normal) -> MemoryStatus {
        MemoryStatus(physicalBytes: 16 * gigabyte, usedBytes: 8 * gigabyte, swapUsedBytes: 0, swapTotalBytes: 0,
                     pressure: pressure, processCount: 0,
                     components: MemoryComponents(appBytes: 4 * gigabyte, wiredBytes: 2 * gigabyte,
                                                  compressedBytes: 2 * gigabyte, cachedBytes: 4 * gigabyte))
    }

    // MARK: - Verfügbarkeit

    /// Akku nur am Mac mit Akku: Ohne eingerichtete Quelle fehlt die Kachel im Katalog; die übrigen sechs stehen immer.
    @Test func batteryTileNeedsABattery() {
        let withoutBattery = Set(TaskManagerSource.allCases).subtracting([.battery])
        #expect(!OverviewTileKind.battery.isAvailable(configured: withoutBattery))
        #expect(OverviewTileKind.battery.isAvailable(configured: Set(TaskManagerSource.allCases)))
        let others: [OverviewTileKind] = [.memory, .disk, .network, .thermal, .loadAverage, .uptime]
        #expect(others.allSatisfy { $0.isAvailable(configured: withoutBattery) })
    }

    // MARK: - Arbeitsspeicher

    /// Legende in 2 × 1 mit kurzen Namen, größere Kacheln mit Betrag je Teil.
    @Test func memoryPartsHaveShortTitlesAndAmounts() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.memory = Self.memory()
        let memory = try #require(Self.overview(snapshot).memory)
        #expect(memory.parts.map(\.title) == ["App", "Zugeordnet", "Komprimiert"])
        #expect(memory.parts.map(\.shortTitle) == ["App", "Zug.", "Kompr."])
        #expect(memory.parts.map { Self.plain($0.amount) } == ["4 GB", "2 GB", "2 GB"])
    }

    @Test func memorySpokenValueNamesShareAndPressure() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.memory = Self.memory(pressure: .warning)
        #expect(try #require(Self.overview(snapshot).memory).spokenValue == "50 %, Druck erhöht")
    }

    @Test func memoryWithoutPressureSaysSoInsteadOfNormal() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.memory = MemoryStatus(physicalBytes: 16 * Self.gigabyte, usedBytes: nil, swapUsedBytes: nil,
                                       swapTotalBytes: nil, pressure: nil, processCount: 0)
        let memory = try #require(Self.overview(snapshot).memory)
        #expect(memory.usedShare == nil)
        #expect(memory.value == "–")
        #expect(memory.parts.isEmpty)
        #expect(memory.spokenValue == "nicht gemessen")
    }

    // MARK: - Datenträger

    /// Freier Platz kurz für 1 × 1 („250 GB“), Größe des Volumes getrennt; der Satz für die Karte bleibt.
    @Test func diskSplitsFreeSpaceAndCapacity() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.drives = [DriveThroughput(id: "disk3", name: "SSD", readPerSecond: 2_000_000, writePerSecond: nil)]
        let volume = VolumeUsage(totalBytes: 1_000_000_000_000, availableBytes: 250_000_000_000)
        let disk = try #require(Self.overview(snapshot, context: MenuBarOverviewContext(startupVolume: volume)).disk)
        #expect(Self.plain(disk.freeAmount) == "250 GB")
        #expect(Self.plain(disk.capacity) == "1 TB")
        #expect(Self.plain(disk.free) == "250 GB frei von 1 TB")
        #expect(Self.plain(disk.spokenValue) == "250 GB frei von 1 TB, Lesen 2,0 MB/s, Schreiben –")
    }

    /// Kacheln sind schmal: drei Stellen genügen („413 GB“ statt „412,88 GB“).
    @Test func diskAmountsUseThreeDigits() throws {
        let volume = VolumeUsage(totalBytes: 994_662_584_320, availableBytes: 412_884_131_840)
        let disk = try #require(Self.overview(context: MenuBarOverviewContext(startupVolume: volume)).disk)
        #expect(Self.plain(disk.freeAmount) == "413 GB")
        #expect(Self.plain(disk.capacity) == "995 GB")
    }

    @Test func diskWithoutVolumeSpeaksOnlyRates() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.drives = [DriveThroughput(id: "disk3", name: "SSD", readPerSecond: nil, writePerSecond: nil)]
        let disk = try #require(Self.overview(snapshot).disk)
        #expect(disk.freeAmount == nil)
        #expect(disk.capacity == nil)
        #expect(disk.spokenValue == "Lesen –, Schreiben –")
    }

    @Test func diskWithoutDriveSpeaksOnlyFreeSpace() throws {
        let volume = VolumeUsage(totalBytes: 1_000_000_000_000, availableBytes: 250_000_000_000)
        let disk = try #require(Self.overview(context: MenuBarOverviewContext(startupVolume: volume)).disk)
        #expect(disk.driveID == nil)
        #expect(Self.plain(disk.spokenValue) == "250 GB frei von 1 TB")
    }

    // MARK: - Netz

    @Test func networkSpokenValueNamesInterfaceAndDirections() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.interfaces = [InterfaceThroughput(name: "en0", receivedPerSecond: 52_000, sentPerSecond: nil,
                                                   displayName: "WLAN", addresses: ["192.168.178.24"],
                                                   isPrimary: true)]
        let network = try #require(Self.overview(snapshot).network)
        // Mit BSD-Namen wie `spokenTitle` (#520): VoiceOver und die Gegenprobe der Default-Route lesen ihn.
        #expect(network.spokenValue == "WLAN en0, empfangen 52 KB/s, gesendet –")
    }

    // MARK: - Thermik und Akku

    @Test func thermalHasShortLowPowerModeForSmallTile() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.thermal = ThermalCondition(state: .nominal, isLowPowerModeEnabled: false)
        let thermal = try #require(Self.overview(snapshot).thermal)
        #expect(thermal.value == "Normal")
        #expect(thermal.lowPowerModeShort == "Sparmodus aus")
        #expect(thermal.spokenValue == "Normal, Energiesparmodus aus")
        snapshot.thermal = ThermalCondition(state: .critical, isLowPowerModeEnabled: true)
        #expect(try #require(Self.overview(snapshot).thermal).lowPowerModeShort == "Sparmodus an")
    }

    /// In 1 × 1 nur der Zustand; dass gedrosselt wird, sagen 2 × 1 und VoiceOver.
    @Test func thermalShortValueFitsTheSmallTile() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.thermal = ThermalCondition(state: .serious, isLowPowerModeEnabled: false)
        let thermal = try #require(Self.overview(snapshot).thermal)
        #expect(thermal.shortValue == "Hoch")
        #expect(thermal.spokenValue == "Hoch – Leistung gedrosselt, Energiesparmodus aus")
        snapshot.thermal = ThermalCondition(state: .fair, isLowPowerModeEnabled: false)
        #expect(try #require(Self.overview(snapshot).thermal).shortValue == "Erhöht")
    }

    /// Zeile unter der Spur in 2 × 1: gedrosselt nur bei hohem Zustand, sonst der Energiesparmodus ausgeschrieben.
    @Test func thermalDetailNamesThrottlingOnlyWhenHigh() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.thermal = ThermalCondition(state: .serious, isLowPowerModeEnabled: true)
        #expect(try #require(Self.overview(snapshot).thermal).detail == "Leistung gedrosselt · Sparmodus an")
        snapshot.thermal = ThermalCondition(state: .nominal, isLowPowerModeEnabled: false)
        #expect(try #require(Self.overview(snapshot).thermal).detail == "Energiesparmodus aus")
    }

    @Test func batterySpokenValueNamesChargeAndState() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.battery = BatteryReading(charge: 0.82, source: .battery)
        #expect(try #require(Self.overview(snapshot).battery).spokenValue == "82 %, Akkubetrieb")
        snapshot.battery = BatteryReading(charge: nil, source: .battery)
        let unknown = try #require(Self.overview(snapshot).battery)
        #expect(unknown.value == "–")
        #expect(unknown.charge == nil)
    }

    // MARK: - Durchschnittslast

    @Test func loadAverageHasOneValuePerWindow() throws {
        let context = MenuBarOverviewContext(loadAverage: LoadAverage(one: 2.414, five: 2.1, fifteen: 1.95))
        let load = try #require(Self.overview(context: context).summary?.loadFigures)
        #expect(load.one == "2,41")
        #expect(load.five == "2,10")
        #expect(load.fifteen == "1,95")
        #expect(load.spokenValue == "1 Minute 2,41, 5 Minuten 2,10, 15 Minuten 1,95")
    }

    @Test func loadAverageMissingWithoutReading() {
        let summary = Self.overview(context: MenuBarOverviewContext(uptime: 60)).summary
        #expect(summary?.loadFigures == nil)
        #expect(summary?.uptimeFigures != nil)
    }

    // MARK: - Laufzeit

    /// Laufzeit in Sekunden und die erwarteten Texte: kurz (1 × 1), ausführlich (2 × 1), gesprochen.
    struct UptimeCase: Sendable, CustomTestStringConvertible {
        let seconds: TimeInterval
        let short: String
        let detailed: String
        let spoken: String

        var testDescription: String { short }
    }

    static let uptimeCases: [UptimeCase] = [
        UptimeCase(seconds: 59, short: "0 min", detailed: "0 min", spoken: "0 Minuten"),
        UptimeCase(seconds: 17 * 60 + 59, short: "17 min", detailed: "17 min", spoken: "17 Minuten"),
        UptimeCase(seconds: 3_600 + 60, short: "1 h 1 min", detailed: "1 h 1 min", spoken: "1 Stunde, 1 Minute"),
        UptimeCase(seconds: 4 * 3_600 + 17 * 60, short: "4 h 17 min", detailed: "4 h 17 min",
                   spoken: "4 Stunden, 17 Minuten"),
        UptimeCase(seconds: 86_400 + 22, short: "1 T 0 h", detailed: "1 T 0 h 0 min",
                   spoken: "1 Tag, 0 Stunden, 0 Minuten"),
        UptimeCase(seconds: 3 * 86_400 + 4 * 3_600 + 17 * 60 + 22, short: "3 T 4 h", detailed: "3 T 4 h 17 min",
                   spoken: "3 Tage, 4 Stunden, 17 Minuten"),
    ]

    /// Auf Minuten genau, damit die Kachel nicht jeden Takt neu zeichnet; Tage und Stunden kurz, gesprochen ausgeschrieben.
    @Test(arguments: uptimeCases)
    func uptimeIsRoundedToMinutes(_ expected: UptimeCase) throws {
        let context = MenuBarOverviewContext(uptime: expected.seconds)
        let uptime = try #require(Self.overview(context: context).summary?.uptimeFigures)
        #expect(uptime.short == expected.short)
        #expect(uptime.detailed == expected.detailed)
        #expect(uptime.spokenValue == expected.spoken)
    }

    /// Gleiche Minute, gleicher Wert: Die Kachel wertet zwischen zwei Takten derselben Minute nicht neu aus.
    @Test func uptimeWithinTheSameMinuteIsEqual() {
        let first = Self.overview(context: MenuBarOverviewContext(uptime: 3_600 + 1)).summary?.uptimeFigures
        let second = Self.overview(context: MenuBarOverviewContext(uptime: 3_600 + 58)).summary?.uptimeFigures
        #expect(first == second)
    }

    @Test func negativeUptimeCountsAsZero() throws {
        let uptime = try #require(Self.overview(context: MenuBarOverviewContext(uptime: -5)).summary?.uptimeFigures)
        #expect(uptime.short == "0 min")
    }
}
