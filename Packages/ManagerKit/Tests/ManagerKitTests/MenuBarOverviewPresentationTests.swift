import Foundation
import GrantryShared
import Testing
@testable import ManagerKit

/// Übersicht der Menüleiste (#495): Karten aus dem Stand des Task-Managers, fehlende Werte nie als 0.
@Suite struct MenuBarOverviewPresentationTests {
    private static func profile(_ name: String) throws -> ChipProfile {
        ChipProfile(facts: try ChipProfileTests.facts(name))
    }

    /// Kernlasten wie `host_processor_info`: Kern `index` hat die Art aus `kinds`, Last `index / 100`.
    private static func cpu(_ kinds: [CoreKind], total: Double? = 0.4, system: Double? = 0.1) -> CPULoad {
        CPULoad(total: total, cores: kinds.enumerated().map { CoreLoad(kind: $1, load: Double($0) / 100) },
                system: system)
    }

    /// Formatter setzen geschützte Leerzeichen vor Einheiten.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private static func m4MaxKinds() -> [CoreKind] {
        Array(repeating: .efficiency, count: 4) + Array(repeating: .performance, count: 12)
    }

    private static func overview(_ snapshot: TaskManagerSnapshot, profile: ChipProfile = ChipProfile(facts: ChipFacts()),
                                 context: MenuBarOverviewContext = MenuBarOverviewContext()) -> MenuBarOverview {
        MenuBarOverviewPresentation.overview(for: snapshot, profile: profile, context: context)
    }

    // MARK: - Kerne

    @Test func coresFollowClustersOfChipTabWithPerformanceFirst() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu(Self.m4MaxKinds())
        let cores = try #require(Self.overview(snapshot, profile: try Self.profile("m4-max")).cores)
        #expect(cores.groups.map(\.label) == ["P0", "P1", "E"])
        #expect(cores.groups.map(\.kind) == [.performance, .performance, .efficiency])
        #expect(cores.groups[0].rings.map(\.id) == Array(4...9))
        #expect(cores.groups[1].rings.map(\.id) == Array(10...15))
        #expect(cores.groups[2].rings.map(\.id) == Array(0...3))
        #expect(cores.groups.flatMap(\.rings).allSatisfy { ring in
            ring.kind == (ring.id < 4 ? .efficiency : .performance)
        })
    }

    @Test func coreRingsCarryLoadAndVoiceOverText() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu(Self.m4MaxKinds())
        let rings = try #require(Self.overview(snapshot, profile: try Self.profile("m4-max")).cores).groups
            .flatMap(\.rings)
        let core5 = try #require(rings.first { $0.id == 5 })
        #expect(core5.load == 0.05)
        #expect(core5.accessibilityLabel == "Leistungskern 5")
        #expect(core5.accessibilityValue == "5 %")
        let core0 = try #require(rings.first { $0.id == 0 })
        #expect(core0.accessibilityLabel == "Effizienzkern 0")
    }

    @Test func averagesPerCoreKindInOrderOfGroups() throws {
        var snapshot = TaskManagerSnapshot()
        // Effizienzkerne 0…3 mit 0–3 %, Leistungskerne 4…15 mit 4–15 %.
        snapshot.cpu = Self.cpu(Self.m4MaxKinds())
        let averages = try #require(Self.overview(snapshot, profile: try Self.profile("m4-max")).cores).averages
        #expect(averages.map(\.kind) == [.performance, .efficiency])
        #expect(averages.map(\.title) == ["Leistungskerne", "Effizienzkerne"])
        #expect(averages.map(\.tag) == ["P", "E"])
        #expect(averages.map(\.coreCount) == [12, 4])
        #expect(abs((averages[0].load ?? 0) - 0.095) < 1e-9)
        #expect(abs((averages[1].load ?? 0) - 0.015) < 1e-9)
        #expect(averages.map(\.value) == ["9 %", "2 %"])
    }

    /// Super- und Leistungskerne wie M5 Max (#589): Kürzel, Titel, VoiceOver und Reihenfolge wie im Chip-Tab.
    @Test func superAndPerformanceCoresKeepTheirClass() throws {
        let profile = CoreKindTests.superAndPerformance
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu(profile.coreKinds(coreCount: 18))
        let cores = try #require(Self.overview(snapshot, profile: profile).cores)
        #expect(cores.groups.map(\.kind) == [.super, .performance])
        #expect(cores.groups.map(\.label) == ["S", "P"])
        #expect(cores.averages.map(\.title) == ["Super-Kerne", "Leistungskerne"])
        #expect(cores.averages.map(\.tag) == ["S", "P"])
        #expect(cores.averages.map(\.coreCount) == [6, 12])
        let rings = cores.groups.flatMap(\.rings)
        #expect(rings.first { $0.id == 12 }?.accessibilityLabel == "Super-Kern 12")
        #expect(rings.first { $0.id == 0 }?.accessibilityLabel == "Leistungskern 0")
    }

    @Test func threeClassesAreAveragedFromFastest() throws {
        let profile = CoreKindTests.threeClasses
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu(profile.coreKinds(coreCount: 14))
        let cores = try #require(Self.overview(snapshot, profile: profile).cores)
        #expect(cores.groups.map(\.kind) == [.super, .performance, .efficiency])
        #expect(cores.averages.map(\.tag) == ["S", "P", "E"])
        #expect(cores.averages.map(\.coreCount) == [4, 6, 4])
    }

    @Test func smallerChipHasOneClusterPerKind() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu([.efficiency, .efficiency, .efficiency, .efficiency,
                                 .performance, .performance, .performance, .performance])
        let cores = try #require(Self.overview(snapshot, profile: try Self.profile("m1")).cores)
        #expect(cores.groups.map(\.kind) == [.performance, .efficiency])
        #expect(cores.groups.map(\.rings.count) == [4, 4])
        #expect(cores.averages.map(\.coreCount) == [4, 4])
    }

    /// Ohne Gerätebaum (Intel, virtuelle Maschine) oder wenn Profil und Messung nicht zusammenpassen: je Kernart eine
    /// Gruppe in der Reihenfolge von „Pro Kern“, ohne Cluster-Kürzel.
    @Test func withoutMatchingProfileGroupsByKind() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu([.unknown, .unknown, .unknown, .unknown])
        let cores = try #require(Self.overview(snapshot, profile: try Self.profile("m4-max")).cores)
        #expect(cores.groups.map(\.kind) == [.unknown])
        #expect(cores.groups[0].label == nil)
        #expect(cores.groups[0].rings.map(\.id) == [0, 1, 2, 3])
        #expect(cores.groups[0].rings[0].accessibilityLabel == "Kern 0")
        #expect(cores.averages.map(\.title) == ["Kerne"])
        #expect(cores.averages[0].tag == nil)
    }

    @Test func missingCoreLoadIsNoMeasurementNotZero() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: nil, cores: [CoreLoad(kind: .performance, load: nil),
                                                   CoreLoad(kind: .efficiency, load: nil)])
        let cores = try #require(Self.overview(snapshot).cores)
        let rings = cores.groups.flatMap(\.rings)
        #expect(rings.allSatisfy { $0.load == nil })
        #expect(rings.allSatisfy { $0.accessibilityValue == "keine Messung" })
        #expect(cores.averages.allSatisfy { $0.load == nil && $0.value == "–" })
    }

    // MARK: - CPU

    @Test func cpuSplitsUserAndSystem() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu([.performance], total: 0.37, system: 0.12)
        let cpu = try #require(Self.overview(snapshot).cpu)
        #expect(cpu.value == "37 %")
        #expect(abs((cpu.user ?? 0) - 0.25) < 1e-9)
        #expect(cpu.system == 0.12)
        #expect(cpu.userText == "25 %")
        #expect(cpu.systemText == "12 %")
        #expect(cpu.clock == nil)
    }

    @Test func cpuWithoutSystemShareShowsDashes() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu([.performance], total: nil, system: nil)
        let cpu = try #require(Self.overview(snapshot).cpu)
        #expect(cpu.value == "–")
        #expect(cpu.user == nil)
        #expect(cpu.userText == "–")
        #expect(cpu.systemText == "–")
    }

    @Test func cpuClockOnlyWithHelperMeasurement() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu([.performance])
        let sensors = SensorReading(clusters: [
            SensorReading.Cluster(name: "E-Cluster", frequencyMHz: 1_000, activeShare: 1),
            SensorReading.Cluster(name: "P0-Cluster", frequencyMHz: 3_500, activeShare: 0.5),
        ], gpuFrequencyMHz: 1_200)
        let overview = Self.overview(snapshot, context: MenuBarOverviewContext(sensors: sensors))
        #expect(overview.cpu?.clock == "3,5 GHz")
    }

    // MARK: - Fehlende Quellen und ausgeblendete Karten

    @Test func emptySnapshotShowsOnlySummary() {
        let overview = Self.overview(TaskManagerSnapshot(), context: MenuBarOverviewContext(uptime: 90))
        #expect(overview.cards == [.summary])
    }

    @Test func cardsFollowFixedOrder() {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu([.performance])
        snapshot.memory = MemoryStatus(physicalBytes: 16, usedBytes: 8, swapUsedBytes: 0, swapTotalBytes: 0,
                                       pressure: .normal, processCount: 1)
        snapshot.gpu = GPULoadReading(utilization: 0.2, usedMemoryBytes: 4)
        snapshot.drives = [DriveThroughput(id: "disk0", name: "SSD", readPerSecond: 1, writePerSecond: 2)]
        snapshot.interfaces = [InterfaceThroughput(name: "en0", receivedPerSecond: 3, sentPerSecond: 4,
                                                   addresses: ["192.168.1.2"], isPrimary: true)]
        snapshot.thermal = ThermalCondition(state: .nominal, isLowPowerModeEnabled: false)
        snapshot.battery = BatteryReading(charge: 0.8, source: .battery)
        snapshot.processes = [ProcessMeasurement(key: ProcessKey(pid: 10, startTime: 1), parentPID: 1, uid: 0,
                                                 name: "kernel_task", cpuLoad: 0.02, memoryBytes: nil,
                                                 diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil)]
        let overview = Self.overview(snapshot, context: MenuBarOverviewContext(uptime: 60))
        #expect(overview.cards == MenuBarOverviewCard.allCases)
    }

    @Test func hiddenCardsAreLeftOut() {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = Self.cpu([.performance])
        let overview = Self.overview(snapshot, context: MenuBarOverviewContext(hidden: [.cores, .summary]))
        #expect(overview.cards == [.cpu])
        #expect(overview.cores == nil)
        #expect(overview.summary == nil)
    }

    @Test func gpuWithoutUtilizationHasNoCard() {
        var snapshot = TaskManagerSnapshot()
        snapshot.gpu = GPULoadReading(utilization: nil, usedMemoryBytes: 4)
        #expect(Self.overview(snapshot).gpu == nil)
    }

    @Test func gpuRingsOnlyForMeasuredValues() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.gpu = GPULoadReading(utilization: 0.44, usedMemoryBytes: nil)
        let gpu = try #require(Self.overview(snapshot).gpu)
        #expect(gpu.rings.map(\.caption) == ["Auslastung"])
        #expect(gpu.rings[0].value == "44 %")
        #expect(gpu.rings[0].fraction == 0.44)

        snapshot.memory = MemoryStatus(physicalBytes: 64 << 30, usedBytes: nil, swapUsedBytes: nil,
                                       swapTotalBytes: nil, pressure: nil, processCount: 0)
        snapshot.gpu = GPULoadReading(utilization: 0.44, usedMemoryBytes: 16 << 30)
        let sensors = SensorReading(gpuFrequencyMHz: 1_200)
        let measured = try #require(Self.overview(snapshot, context: MenuBarOverviewContext(sensors: sensors)).gpu)
        #expect(measured.rings.map(\.caption) == ["Auslastung", "Speicher"])
        #expect(measured.rings[1].fraction == 0.25)
        #expect(measured.clock == "1,2 GHz")
    }

    // MARK: - Prozesse

    @Test func topThreeProcessesByCPUGroupedByApp() throws {
        let app = RunningApp(pid: 100, bundleID: "com.example.editor", bundlePath: "/Applications/Editor.app",
                             name: "Editor")
        func process(_ pid: Int32, parent: Int32 = 1, uid: UInt32 = 501, name: String, load: Double?,
                     path: String? = nil) -> ProcessMeasurement {
            ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: parent, uid: uid, name: name,
                               cpuLoad: load, memoryBytes: nil, diskReadPerSecond: nil, diskWritePerSecond: nil,
                               threadCount: nil, executablePath: path)
        }
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [
            process(100, name: "Editor", load: 0.01),
            process(101, parent: 100, name: "Editor Helper", load: 0.02,
                    path: "/Applications/Editor.app/Contents/MacOS/Helper"),
            process(200, uid: 0, name: "WindowServer", load: 0.025),
            process(300, name: "mdworker", load: 0.001),
            process(400, name: "idle", load: nil),
            process(500, name: "cloudd", load: 0.004),
        ]
        let context = MenuBarOverviewContext(apps: [app], currentUID: 501)
        let processes = try #require(Self.overview(snapshot, context: context).processes)
        #expect(processes.entries.map(\.name) == ["Editor", "WindowServer", "cloudd"])
        #expect(processes.entries[0].app == app)
        #expect(processes.entries[1].isSystem)
        #expect(processes.entries.map { Self.plain($0.value) } == ["3,0 %", "2,5 %", "0,4 %"])
    }

    @Test func processesBeforeFirstRateHaveNoEntries() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [ProcessMeasurement(key: ProcessKey(pid: 1, startTime: 1), parentPID: 0, uid: 0,
                                                 name: "launchd", cpuLoad: nil, memoryBytes: nil,
                                                 diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: nil)]
        let processes = try #require(Self.overview(snapshot).processes)
        #expect(processes.entries.isEmpty)
    }

    // MARK: - Speicher, Datenträger, Netz, Thermik, Akku, Zusammenfassung

    @Test func memoryShowsCompositionPressureAndSwap() throws {
        var snapshot = TaskManagerSnapshot()
        let gigabyte: UInt64 = 1 << 30
        snapshot.memory = MemoryStatus(
            physicalBytes: 16 * gigabyte, usedBytes: 8 * gigabyte, swapUsedBytes: gigabyte, swapTotalBytes: 2 * gigabyte,
            pressure: .warning, processCount: 0,
            components: MemoryComponents(appBytes: 4 * gigabyte, wiredBytes: 2 * gigabyte, compressedBytes: 2 * gigabyte,
                                         cachedBytes: 4 * gigabyte))
        let memory = try #require(Self.overview(snapshot).memory)
        #expect(memory.usedShare == 0.5)
        #expect(memory.value == "50 %")
        #expect(memory.parts.map(\.kind) == [.app, .wired, .compressed])
        #expect(memory.parts.map(\.share) == [0.25, 0.125, 0.125])
        #expect(memory.pressure == .warning)
        #expect(memory.pressureText == "erhöht")
        #expect(Self.plain(memory.swap) == "1 GB von 2 GB")
    }

    @Test func diskShowsStartupVolumeAndFirstDrive() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.drives = [DriveThroughput(id: "disk3", name: "APPLE SSD", readPerSecond: 2_000_000,
                                           writePerSecond: nil)]
        let volume = VolumeUsage(totalBytes: 1_000_000_000_000, availableBytes: 250_000_000_000)
        let disk = try #require(Self.overview(snapshot, context: MenuBarOverviewContext(startupVolume: volume)).disk)
        #expect(disk.driveID == "disk3")
        #expect(disk.usedShare == 0.75)
        #expect(disk.free.map(Self.plain) == "250 GB frei von 1 TB")
        #expect(disk.read == "2,0 MB/s")
        #expect(disk.write == "–")
    }

    @Test func diskWithoutVolumeOmitsFreeSpace() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.drives = [DriveThroughput(id: "disk3", name: "SSD", readPerSecond: 0, writePerSecond: 0)]
        let disk = try #require(Self.overview(snapshot).disk)
        #expect(disk.free == nil)
        #expect(disk.usedShare == nil)
    }

    @Test func networkUsesInterfaceOfDefaultRoute() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.interfaces = [
            InterfaceThroughput(name: "en0", receivedPerSecond: 5, sentPerSecond: 6, displayName: "WLAN",
                                addresses: ["192.168.178.24"]),
            InterfaceThroughput(name: "en8", receivedPerSecond: 52_000, sentPerSecond: 6_000, displayName: "USB LAN",
                                addresses: ["192.168.178.30"], isPrimary: true),
        ]
        let network = try #require(Self.overview(snapshot).network)
        #expect(network.interfaceName == "en8")
        #expect(network.title == "USB LAN")
        #expect(network.received == "52 KB/s")
        #expect(network.sent == "6,0 KB/s")
        // VoiceOver und die Gegenprobe der Default-Route (plausibility.py) brauchen den BSD-Namen, den die Karte nicht zeigt.
        #expect(network.spokenTitle == "USB LAN en8")
    }

    @Test func networkWithoutDisplayNameSpeaksBSDNameOnce() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.interfaces = [InterfaceThroughput(name: "en0", receivedPerSecond: 5, sentPerSecond: 6,
                                                   addresses: ["192.168.178.24"], isPrimary: true)]
        let network = try #require(Self.overview(snapshot).network)
        #expect(network.title == "en0")
        #expect(network.spokenTitle == "en0")
    }

    @Test func thermalShowsStateWithoutTemperatures() throws {
        var snapshot = TaskManagerSnapshot()
        snapshot.thermal = ThermalCondition(state: .serious, isLowPowerModeEnabled: true)
        let thermal = try #require(Self.overview(snapshot).thermal)
        #expect(thermal.state == .serious)
        #expect(thermal.value == "Hoch – Leistung gedrosselt")
        #expect(thermal.level == 0.75)
        #expect(thermal.lowPowerMode == "Energiesparmodus an")
    }

    @Test func batteryOnlyWithBattery() throws {
        #expect(Self.overview(TaskManagerSnapshot()).battery == nil)
        var snapshot = TaskManagerSnapshot()
        snapshot.battery = BatteryReading(charge: 0.82, source: .externalPower, isCharging: true)
        let battery = try #require(Self.overview(snapshot).battery)
        #expect(battery.charge == 0.82)
        #expect(battery.value == "82 %")
        #expect(battery.state == "Lädt")
        #expect(battery.isCharging)
    }

    @Test func summaryShowsLoadAverageAndUptime() throws {
        let context = MenuBarOverviewContext(loadAverage: LoadAverage(one: 2.5, five: 1.25, fifteen: 0.5),
                                             uptime: 90_061)
        let summary = try #require(Self.overview(TaskManagerSnapshot(), context: context).summary)
        #expect(summary.loadAverage == "2,50 · 1,25 · 0,50")
        #expect(summary.uptime == "1:01:01:01")
    }

    /// Sprung in „Leistung“ auf die Kachel der Karte: Datenträger das erste Laufwerk, Netz die Schnittstelle der Karte.
    @Test func cardsJumpToTheirTile() {
        var snapshot = TaskManagerSnapshot()
        snapshot.drives = [DriveThroughput(id: "disk3", name: "SSD", readPerSecond: 0, writePerSecond: 0)]
        snapshot.interfaces = [InterfaceThroughput(name: "en8", receivedPerSecond: 1, sentPerSecond: 1,
                                                   addresses: ["10.0.0.2"], isPrimary: true)]
        let overview = Self.overview(snapshot)
        #expect(overview.metric(for: .cpu) == .cpu)
        #expect(overview.metric(for: .gpu) == .gpu)
        #expect(overview.metric(for: .memory) == .memory)
        #expect(overview.metric(for: .disk) == .drive("disk3"))
        #expect(overview.metric(for: .network) == .interface("en8"))
        #expect(overview.metric(for: .processes) == nil)
        #expect(Self.overview(TaskManagerSnapshot()).metric(for: .disk) == nil)
    }

    /// Das offene Popover liest nur die Quellen sichtbarer Karten: ohne Prozess-Karte keine Prozessquelle (#495).
    @Test func popoverReadsOnlySourcesOfShownCards() {
        #expect(MenuBarOverviewPresentation.sources(hiding: []) == Set(TaskManagerSource.allCases))
        #expect(MenuBarOverviewPresentation.sources(hiding: [.processes, .gpu, .battery])
            == [.cpu, .memory, .disks, .interfaces])
        #expect(MenuBarOverviewPresentation.sources(hiding: [.cpu]).contains(.cpu))
    }

    @Test func summaryWithoutValuesIsLeftOut() {
        #expect(Self.overview(TaskManagerSnapshot()).summary == nil)
    }
}
