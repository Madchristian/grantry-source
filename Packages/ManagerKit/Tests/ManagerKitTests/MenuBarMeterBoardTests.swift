import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Stand der Statusobjekte (#482, Bewertung 2026.11.9 Mangel 2): Jedes Setzen eines Statusobjekts kostet unter macOS 26
/// mehrere Millisekunden; daher meldet die Tafel je Takt nur die Elemente, deren Anzeige sich geändert hat.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct MenuBarMeterBoardTests {
    private static let memory = MemoryStatus(physicalBytes: 16, usedBytes: 8, swapUsedBytes: nil, swapTotalBytes: nil,
                                             pressure: .normal, processCount: 0)

    private let settings = InMemorySettingsStore()
    private let taskManager = TaskManagerModel(
        sources: TaskManagerSources(memory: ScriptedMetricSource(readings: [Self.memory])), clock: TestClock(),
        failures: SourceFailureLog(report: { _, _ in })
    )

    private func meters(_ shown: Set<MenuBarMeterKind>) -> MenuBarMetersModel {
        let meters = MenuBarMetersModel(taskManager: taskManager, settings: settings,
                                        configured: Set(TaskManagerSource.allCases))
        for kind in shown { meters.setShown(true, for: kind) }
        return meters
    }

    private func frame(cpu: Double?, thermal: ProcessInfo.ThermalState = .nominal) -> TaskManagerFrame {
        var frame = TaskManagerFrame.empty(interval: .twoSeconds)
        frame.snapshot.cpu = cpu.map { CPULoad(total: $0, cores: []) }
        frame.snapshot.thermal = ThermalCondition(state: thermal, isLowPowerModeEnabled: false)
        return frame
    }

    @Test func entriesCoverOnlyShownElementsInSettingsOrder() {
        let meters = meters([.thermal, .cpu])
        meters.setStyle(.number, for: .cpu)
        meters.showsTags = false
        let entries = meters.entries(in: frame(cpu: 0.25))
        #expect(entries.map(\.kind) == [.cpu, .thermal])
        #expect(entries.map(\.style) == [.number, MenuBarMeterKind.thermal.defaultStyle])
        #expect(entries.allSatisfy { !$0.showsTags })
        #expect(entries.first?.reading == MenuBarMeterPresentation.reading(for: .cpu, in: frame(cpu: 0.25)))
    }

    @Test func firstUpdateSetsEveryShownElement() {
        let meters = meters([.cpu, .thermal])
        var board = MenuBarMeterBoard()
        let changes = board.update(meters.entries(in: frame(cpu: 0.25)))
        #expect(changes.updated.map(\.kind) == [.cpu, .thermal])
        #expect(changes.removed.isEmpty)
    }

    /// Thermik bleibt zwischen zwei Wechseln gleich und wird nicht neu gesetzt; ein gleicher Takt setzt gar nichts.
    @Test func onlyChangedElementsAreSetAgain() {
        let meters = meters([.cpu, .thermal])
        var board = MenuBarMeterBoard()
        _ = board.update(meters.entries(in: frame(cpu: 0.25)))
        #expect(board.update(meters.entries(in: frame(cpu: 0.25))) == MenuBarMeterChanges())
        let changes = board.update(meters.entries(in: frame(cpu: 0.5)))
        #expect(changes.updated.map(\.kind) == [.cpu])
        #expect(changes.removed.isEmpty)
    }

    @Test func styleAndTagChangesSetTheElementAgain() {
        let meters = meters([.cpu, .thermal])
        var board = MenuBarMeterBoard()
        _ = board.update(meters.entries(in: frame(cpu: 0.25)))
        meters.setStyle(.bar, for: .cpu)
        #expect(board.update(meters.entries(in: frame(cpu: 0.25))).updated.map(\.kind) == [.cpu])
        meters.showsTags = false
        #expect(board.update(meters.entries(in: frame(cpu: 0.25))).updated.map(\.kind) == [.cpu, .thermal])
    }

    @Test func switchedOffElementsAreRemovedOnce() {
        let meters = meters([.cpu, .thermal])
        var board = MenuBarMeterBoard()
        _ = board.update(meters.entries(in: frame(cpu: 0.25)))
        meters.setShown(false, for: .thermal)
        let changes = board.update(meters.entries(in: frame(cpu: 0.25)))
        #expect(changes.updated.isEmpty)
        #expect(changes.removed == [.thermal])
        #expect(board.update(meters.entries(in: frame(cpu: 0.25))) == MenuBarMeterChanges())
    }

    /// Nach geändertem Kontrast oder neu angelegtem Statusobjekt zeichnet der nächste Takt alles neu.
    @Test func invalidatingSetsEverythingAgain() {
        let meters = meters([.cpu, .thermal])
        var board = MenuBarMeterBoard()
        _ = board.update(meters.entries(in: frame(cpu: 0.25)))
        board.invalidate()
        #expect(board.update(meters.entries(in: frame(cpu: 0.25))).updated.map(\.kind) == [.cpu, .thermal])
    }
}
