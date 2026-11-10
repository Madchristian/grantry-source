import Foundation
import Testing
@testable import ManagerKit

/// Werte der Menüleisten-Elemente (TM-17.1, #464): Texte wie im Leistung-Tab, Verlauf der letzten 30 Punkte, Pegel,
/// Befund und VoiceOver; fehlende Werte als „–“, nie 0.
@Suite struct MenuBarMeterPresentationTests {
    private static let memory = MemoryStatus(physicalBytes: 16, usedBytes: 4, swapUsedBytes: nil, swapTotalBytes: nil,
                                             pressure: .normal, processCount: 0)

    /// Ein Basistakt, danach je Eintrag ein Takt mit `percent` % CPU-Last eines Kerns.
    private func frame(cpuPercents: [UInt64]) -> TaskManagerFrame {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond, fallbackCoreCount: 1)
        var busy: UInt64 = 0, idle: UInt64 = 0
        var frame = TaskManagerFrame.empty(interval: .oneSecond)
        for (tick, percent) in ([0] + cpuPercents).enumerated() {
            busy += percent
            idle += 100 - percent
            let cores = CPULoadReading(cores: [CoreTicks(kind: .performance, busy: busy, idle: idle)])
            frame = accumulator.ingest(TaskManagerReadings(cpu: .success(cores), memory: .success(Self.memory)),
                                       elapsed: tick == 0 ? nil : .seconds(1))
        }
        return frame
    }

    private func frame(_ change: (inout TaskManagerSnapshot) -> Void) -> TaskManagerFrame {
        var frame = TaskManagerFrame.empty(interval: .oneSecond)
        change(&frame.snapshot)
        return frame
    }

    private func reading(_ kind: MenuBarMeterKind, _ frame: TaskManagerFrame) -> MenuBarMeterReading {
        MenuBarMeterPresentation.reading(for: kind, in: frame)
    }

    @Test func emptyFrameShowsDashesAndNoHistory() {
        for kind in MenuBarMeterKind.allCases where kind != .thermal {
            let reading = reading(kind, .empty(interval: .oneSecond))
            #expect(reading.history.isEmpty, "\(kind)")
            #expect(reading.lines.allSatisfy { $0.contains("–") }, "\(kind): \(reading.lines)")
            #expect(!reading.isFinding)
        }
    }

    @Test func overviewKeepsCPUHistoryAndMemoryLevel() {
        let reading = reading(.overview, frame(cpuPercents: [25, 50]))
        #expect(reading.history == [0.25, 0.5])
        #expect(reading.gauge == .level(0.25))
        #expect(reading.lines.isEmpty)
        #expect(reading.accessibilityLabel == "Übersicht")
        #expect(reading.accessibilityValue == "CPU 50 %, Arbeitsspeicher 25 %")
    }

    @Test func cpuShowsTotalLoadWithTheNewestThirtyPoints() {
        let percents = (0..<45).map { UInt64($0 % 10 * 10) }
        let reading = reading(.cpu, frame(cpuPercents: percents))
        #expect(reading.history.count == MenuBarMeterPresentation.pointCount)
        #expect(reading.history.last == 0.4)
        #expect(reading.lines == ["40 %"])
        #expect(reading.gauge == .level(0.4))
        #expect(reading.tag == "CPU")
        #expect(reading.accessibilityLabel == "CPU")
        #expect(reading.accessibilityValue == "40 %")
    }

    @Test func memoryShowsUsedShareAndPressureAsFinding() {
        let normal = reading(.memory, frame(cpuPercents: [10]))
        #expect(normal.lines == ["25 %"])
        #expect(!normal.history.isEmpty && normal.history.allSatisfy { $0 == 0.25 })
        #expect(!normal.isFinding)
        let pressed = reading(.memory, frame { snapshot in
            snapshot.memory = MemoryStatus(physicalBytes: 16, usedBytes: 14, swapUsedBytes: nil, swapTotalBytes: nil,
                                           pressure: .warning, processCount: 0)
        })
        #expect(pressed.lines == ["88 %"])
        #expect(pressed.isFinding)
        #expect(pressed.accessibilityValue == "88 %, Speicherdruck erhöht")
    }

    @Test func gpuShowsUtilization() {
        let reading = reading(.gpu, frame { $0.gpu = GPULoadReading(utilization: 0.16, usedMemoryBytes: nil) })
        #expect(reading.lines == ["16 %"])
        #expect(reading.gauge == .level(0.16))
    }

    @Test func networkShowsBothDirectionsOfTheRoutedInterface() {
        let reading = reading(.network, frame { snapshot in
            snapshot.interfaces = [
                InterfaceThroughput(name: "en0", receivedPerSecond: 5, sentPerSecond: 6, addresses: ["192.168.1.2"]),
                InterfaceThroughput(name: "en8", receivedPerSecond: 3_600_000, sentPerSecond: 48_000,
                                    addresses: ["192.168.1.3"], isPrimary: true),
            ]
        })
        #expect(reading.lines == ["↓ 3,6 MB/s", "↑ 48 KB/s"])
        #expect(reading.accessibilityValue == "empfangen 3,6 MB/s, gesendet 48 KB/s")
        #expect(reading.gauge == nil)
    }

    /// Gemeinsame Skala mit mindestens 1 MB/s wie `MirrorGraph`: wenig Verkehr bleibt flach.
    @Test func mirroredHistoryIsScaledTogether() {
        let scaled = MenuBarMeterPresentation.mirrored(upper: [2_000_000, nil], lower: [500_000, 1_000_000])
        #expect(scaled.upper == [1, nil])
        #expect(scaled.lower == [0.25, 0.5])
        let quiet = MenuBarMeterPresentation.mirrored(upper: [100_000], lower: [0])
        #expect(quiet.upper == [0.1])
    }

    @Test func diskShowsReadAndWriteOfTheFirstDrive() {
        let reading = reading(.disk, frame { snapshot in
            snapshot.drives = [DriveThroughput(id: "disk0", name: "SSD", readPerSecond: 42_000_000,
                                               writePerSecond: 3_100_000)]
        })
        #expect(reading.lines == ["L 42 MB/s", "S 3,1 MB/s"])
        #expect(reading.accessibilityValue == "lesen 42 MB/s, schreiben 3,1 MB/s")
    }

    @Test(arguments: [(ProcessInfo.ThermalState.nominal, "Normal", 0.25, false),
                      (.fair, "Erhöht", 0.5, false), (.serious, "Hoch", 0.75, true), (.critical, "Kritisch", 1, true)])
    func thermalShowsStateAndFlagsThrottling(_ state: ProcessInfo.ThermalState, _ text: String, _ level: Double,
                                             _ finding: Bool) {
        let reading = reading(.thermal, frame { $0.thermal = ThermalCondition(state: state, isLowPowerModeEnabled: false) })
        #expect(reading.lines == [text])
        #expect(reading.gauge == .thermometer(level))
        #expect(reading.isFinding == finding)
        #expect(reading.accessibilityValue == "\(text), Energiesparmodus aus")
    }

    @Test func thermalWithoutStateShowsDash() {
        let reading = reading(.thermal, .empty(interval: .oneSecond))
        #expect(reading.lines == ["–"])
        #expect(reading.gauge == .thermometer(nil))
    }

    @Test func batteryShowsChargeChargingAndLowChargeAsFinding() {
        let charging = reading(.battery, frame { $0.battery = BatteryReading(charge: 0.82, source: .externalPower,
                                                                             isCharging: true) })
        #expect(charging.lines == ["82 %"])
        #expect(charging.gauge == .battery(0.82, isCharging: true))
        #expect(charging.accessibilityValue == "82 %, wird geladen")
        let low = reading(.battery, frame { $0.battery = BatteryReading(charge: 0.12, source: .battery) })
        #expect(low.isFinding)
        #expect(low.accessibilityValue == "12 %")
        let lowCharging = reading(.battery, frame { $0.battery = BatteryReading(charge: 0.12, source: .externalPower,
                                                                                isCharging: true) })
        #expect(!lowCharging.isFinding)
    }

    @Test func widthCandidatesCoverEveryValue() {
        for kind in MenuBarMeterKind.allCases where kind != .overview {
            #expect(!MenuBarMeterPresentation.reading(for: kind, in: .empty(interval: .oneSecond)).widest.isEmpty)
        }
    }

    @Test func kindsOfferTheirStylesAndSources() {
        #expect(MenuBarMeterKind.overview.styles == [.graphAndBar])
        #expect(MenuBarMeterKind.cpu.defaultStyle == .numberAndGraph)
        #expect(MenuBarMeterKind.network.styles == [.number, .graph, .numberAndGraph])
        #expect(MenuBarMeterKind.thermal.styles == [.number, .bar, .numberAndBar])
        #expect(MenuBarMeterKind.overview.sources == [.cpu, .memory, .disks, .interfaces])
        #expect(MenuBarMeterKind.thermal.sources.isEmpty)
        #expect(MenuBarMeterKind.battery.sources == [.battery])
    }
}
