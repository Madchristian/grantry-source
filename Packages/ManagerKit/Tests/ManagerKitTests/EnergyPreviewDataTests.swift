import Testing
@testable import ManagerKit

#if DEBUG
@Suite struct EnergyPreviewDataTests {
    @Test func previewShowsBatteryTrendAndEveryLevel() throws {
        let frame = EnergyPreviewData.frame
        #expect(frame.snapshot.battery?.systemMilliwatts != nil)
        #expect(frame.snapshot.processes.contains { $0.energyTrendMilliwatts != nil })
        #expect(frame.history.points(for: .systemPower, in: .fiveMinutes).count > 30)
        let levels = Set(frame.snapshot.processes.compactMap(\.energyTrendMilliwatts).map(EnergyLevel.init(milliwatts:)))
        #expect(levels == Set(EnergyLevel.allCases))
    }

    @Test func foreignProcessesHaveNoEnergy() {
        let foreign = EnergyPreviewData.frame.snapshot.processes.filter { $0.uid != ProcessListPreviewData.currentUID }
        #expect(!foreign.isEmpty)
        #expect(foreign.allSatisfy { $0.energyMilliwatts == nil })
    }

    @Test func previewWithoutBatteryGraphsOwnProcesses() {
        let frame = EnergyPreviewData.frameWithoutBattery
        #expect(frame.snapshot.battery == nil)
        #expect(EnergyPresentation.powerMetric(for: frame.snapshot.battery) == .energyTotal)
        #expect(!frame.history.points(for: .energyTotal, in: .oneMinute).isEmpty)
    }

    @Test func chargingPreviewShowsAdapterPanel() throws {
        let frame = EnergyPreviewData.frameCharging
        let panel = try #require(EnergyPresentation.chargingPanel(for: frame.snapshot.battery))
        #expect(panel.detail == "pd charger")
        #expect(panel.stats.map(\.value).first == "100 W")
        #expect(panel.stats.map(\.value)[2] == "Lädt")
        #expect(EnergyPresentation.chargingPanel(for: EnergyPreviewData.frame.snapshot.battery) == nil)
    }

    @Test func presentationGroupsByEnergy() throws {
        let presentation = EnergyPreviewData.presentation(for: EnergyPreviewData.frame)
        let first = try #require(presentation.rows.first { if case .entry = $0.kind { true } else { false } })
        #expect(first.title == "Xcode")
        #expect(presentation.headerValue(.energy) != "–")
    }
}
#endif
