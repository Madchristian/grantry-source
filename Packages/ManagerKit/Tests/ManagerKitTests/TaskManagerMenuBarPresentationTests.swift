import Testing
@testable import ManagerKit

@Suite struct TaskManagerMenuBarPresentationTests {
    private static let memory = MemoryStatus(physicalBytes: 16, usedBytes: 4, swapUsedBytes: nil, swapTotalBytes: nil,
                                             pressure: .normal, processCount: 0)

    @Test func popoverShowsCPUMemoryFirstDriveAndBusiestInterfaceWithoutDefaultRoute() {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.5, cores: [])
        snapshot.memory = Self.memory
        snapshot.drives = [DriveThroughput(id: "disk0", name: "SSD", readPerSecond: 1, writePerSecond: 2),
                           DriveThroughput(id: "disk4", name: "USB", readPerSecond: 3, writePerSecond: 4)]
        snapshot.interfaces = [
            InterfaceThroughput(name: "lo0", receivedPerSecond: 0, sentPerSecond: 0, addresses: ["127.0.0.1"]),
            InterfaceThroughput(name: "en0", receivedPerSecond: 5, sentPerSecond: 6, displayName: "WLAN",
                                addresses: ["192.168.178.24"]),
            InterfaceThroughput(name: "en5", receivedPerSecond: 1, sentPerSecond: 2, addresses: ["10.0.0.2"]),
        ]
        snapshot.gpu = GPULoadReading(utilization: 0.3, usedMemoryBytes: nil)
        let tiles = TaskManagerMenuBarPresentation.popoverTiles(for: snapshot,
                                                                configured: Set(TaskManagerSource.allCases))
        #expect(tiles.map(\.metric) == [.cpu, .memory, .drive("disk0"), .interface("en0")])
        #expect(tiles.last?.title == "WLAN")
    }

    /// Bewertung 2026.11.7-1188, Mangel 4: Der Verkehr läuft über die Schnittstelle der Default-Route, nicht über
    /// die erste in der Liste.
    @Test func popoverShowsInterfaceOfDefaultRoute() {
        var snapshot = TaskManagerSnapshot()
        snapshot.interfaces = [
            InterfaceThroughput(name: "en0", receivedPerSecond: 5, sentPerSecond: 6, displayName: "WLAN",
                                addresses: ["192.168.178.24"]),
            InterfaceThroughput(name: "en8", receivedPerSecond: 50_000, sentPerSecond: 600, displayName: "USB LAN",
                                addresses: ["192.168.178.30"], isPrimary: true),
        ]
        let tiles = TaskManagerMenuBarPresentation.popoverTiles(for: snapshot, configured: [.interfaces])
        #expect(tiles.map(\.metric) == [.interface("en8")])
    }

    @Test func popoverLeavesOutWhatIsNotMeasured() {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.5, cores: [])
        #expect(TaskManagerMenuBarPresentation.popoverTiles(for: snapshot, configured: [.cpu]).map(\.metric) == [.cpu])
    }
}

/// Popover je Element (TM-17.3, #466).
@Suite struct MenuBarMeterPopoverPresentationTests {
    private func snapshot() -> TaskManagerSnapshot {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.38, cores: [])
        snapshot.gpu = GPULoadReading(utilization: 0.2, usedMemoryBytes: nil)
        snapshot.drives = [DriveThroughput(id: "disk0", name: "SSD", readPerSecond: 1, writePerSecond: 2)]
        snapshot.interfaces = [InterfaceThroughput(name: "en8", receivedPerSecond: 5, sentPerSecond: 6,
                                                   addresses: ["192.168.1.3"], isPrimary: true)]
        return snapshot
    }

    @Test func everyMeasuredElementHasItsTile() {
        let all = Set(TaskManagerSource.allCases)
        let metrics = MenuBarMeterKind.allCases.map {
            TaskManagerMenuBarPresentation.tile(for: $0, in: snapshot(), configured: all)?.metric
        }
        #expect(metrics == [nil, .cpu, .gpu, .memory, .interface("en8"), .drive("disk0"), nil, nil])
    }

    @Test func statsLeaveOutProcessFigures() throws {
        let tile = try #require(TaskManagerMenuBarPresentation.tile(for: .cpu, in: snapshot(),
                                                                    configured: [.cpu]))
        let titles = TaskManagerMenuBarPresentation.stats(for: tile, in: snapshot(), uptime: 60).map(\.title)
        #expect(titles == ["Auslastung", "Kerne", "Laufzeit"])
    }

    @Test func thermalDetailNamesStateAndLowPowerMode() {
        let calm = TaskManagerMenuBarPresentation.thermalDetail(.nominal)
        #expect(calm.value == "Normal")
        #expect(calm.items == [SystemVerdict.Item(text: "Thermik normal", tone: .positive),
                               SystemVerdict.Item(text: "Energiesparmodus aus", tone: .neutral)])
        let hot = TaskManagerMenuBarPresentation.thermalDetail(ThermalCondition(state: .serious,
                                                                                isLowPowerModeEnabled: true))
        #expect(hot.items.first == SystemVerdict.Item(text: "Thermik hoch", tone: .warning))
        #expect(hot.fields.map(\.value) == ["Hoch", "an"])
        #expect(TaskManagerMenuBarPresentation.thermalDetail(nil).value == "–")
    }
}
