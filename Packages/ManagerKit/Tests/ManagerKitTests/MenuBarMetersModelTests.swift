import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Elemente der Menüleiste (TM-17.1, #464): Einstellungen, Migration der Anzeige „Auslastung“ aus TM6 und Messbetrieb
/// nur mit den Quellen der eingeschalteten Elemente.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct MenuBarMetersModelTests {
    private static let memory = MemoryStatus(physicalBytes: 16, usedBytes: 8, swapUsedBytes: nil, swapTotalBytes: nil,
                                             pressure: .normal, processCount: 0)

    private let settings = InMemorySettingsStore()
    private let taskManager = TaskManagerModel(
        sources: TaskManagerSources(memory: ScriptedMetricSource(readings: [Self.memory])), clock: TestClock(),
        failures: SourceFailureLog(report: { _, _ in })
    )

    private func model(configured: Set<TaskManagerSource> = Set(TaskManagerSource.allCases)) -> MenuBarMetersModel {
        MenuBarMetersModel(taskManager: taskManager, settings: settings, configured: configured)
    }

    @Test func everythingIsOffByDefault() async {
        let model = model()
        model.activate()
        #expect(MenuBarMeterKind.allCases.allSatisfy { !model.isShown($0) })
        #expect(!taskManager.isRunning)
        await taskManager.stopAndWait()
    }

    /// Erster Start nach dem Update wie vorher: Nur „Auslastung“, und nur wenn sie an war.
    @Test func earlierOverviewChoiceIsTakenOver() async {
        settings.set(true, forKey: MenuBarMetersModel.legacyStorageKey)
        let model = model()
        #expect(model.isShown(.overview))
        #expect(MenuBarMeterKind.allCases.filter(model.isShown) == [.overview])
        #expect(!taskManager.isRunning)
        model.activate()
        #expect(taskManager.isRunning)
        #expect(taskManager.selectedSources == [.cpu, .memory, .disks, .interfaces])
        await taskManager.stopAndWait()
    }

    @Test func switchingStartsStopsAndIsRemembered() async {
        let model = model()
        model.activate()
        model.setShown(true, for: .cpu)
        #expect(taskManager.isRunning)
        #expect(taskManager.selectedSources == [.cpu])
        model.setShown(true, for: .gpu)
        #expect(taskManager.selectedSources == [.cpu, .gpu])
        #expect(self.model().isShown(.gpu))
        model.setShown(false, for: .cpu)
        model.setShown(false, for: .gpu)
        #expect(!taskManager.isRunning)
        #expect(!self.model().isShown(.cpu))
        await taskManager.stopAndWait()
    }

    /// Thermik braucht keine Quelle (`ThermalStateSource`); der Takt läuft trotzdem, damit die Anzeige mitgeht.
    @Test func thermalAloneMeasuresNoSource() async {
        let model = model()
        model.activate()
        model.setShown(true, for: .thermal)
        #expect(taskManager.isRunning)
        #expect(taskManager.selectedSources.isEmpty)
        await taskManager.stopAndWait()
    }

    @Test func switchingBeforeActivateOnlyRemembers() async {
        let model = model()
        model.setShown(true, for: .memory)
        #expect(!taskManager.isRunning)
        #expect(self.model().isShown(.memory))
        await taskManager.stopAndWait()
    }

    @Test func switchingOffKeepsTheWindowMeasuring() async {
        let model = model()
        model.activate()
        taskManager.start(for: .window)
        model.setShown(true, for: .cpu)
        model.setShown(false, for: .cpu)
        #expect(taskManager.isRunning)
        #expect(taskManager.selectedSources == Set(TaskManagerSource.allCases))
        await taskManager.stopAndWait()
    }

    @Test func stylesAreRememberedAndLimitedToTheAllowedOnes() {
        let model = model()
        #expect(model.style(for: .cpu) == .numberAndGraph)
        model.setStyle(.bar, for: .cpu)
        model.setStyle(.bar, for: .network)
        #expect(self.model().style(for: .cpu) == .bar)
        #expect(self.model().style(for: .network) == .number)
        model.showsTags = false
        #expect(!self.model().showsTags)
    }

    @Test func elementWithoutSourceIsUnavailable() {
        let model = model(configured: Set(TaskManagerSource.allCases).subtracting([.battery]))
        #expect(!model.isAvailable(.battery))
        #expect(model.isAvailable(.thermal))
        model.setShown(true, for: .battery)
        #expect(!model.isShown(.battery))
    }

    /// Karten der Übersicht (#495): alle sichtbar, einzeln ausblendbar und gemerkt.
    @Test func overviewCardsCanBeHiddenAndAreRemembered() {
        let model = model()
        #expect(MenuBarOverviewCard.allCases.allSatisfy(model.isCardShown))
        model.setCardShown(false, for: .gpu)
        model.setCardShown(false, for: .processes)
        model.setCardShown(true, for: .processes)
        #expect(!model.isCardShown(.gpu))
        #expect(self.model().hiddenCards == [.gpu])
    }

    /// Einstellungen aus der Zeit vor der Übersicht kennen keine Karten; sie bleiben trotzdem lesbar.
    @Test func settingsWithoutCardsStayReadable() {
        settings.set(Data(#"{"shown":["cpu"],"styles":{"cpu":"bar"},"showsTags":false}"#.utf8),
                     forKey: MenuBarMetersModel.storageKey)
        let model = model()
        #expect(model.isShown(.cpu))
        #expect(model.style(for: .cpu) == .bar)
        #expect(!model.showsTags)
        #expect(model.hiddenCards.isEmpty)
    }

    @Test func unreadableSettingsFallBackToDefaults() {
        settings.set(Data("kaputt".utf8), forKey: MenuBarMetersModel.storageKey)
        settings.set(true, forKey: MenuBarMetersModel.legacyStorageKey)
        let model = model()
        #expect(MenuBarMeterKind.allCases.filter(model.isShown) == [.overview])
        #expect(model.showsTags)
    }
}
