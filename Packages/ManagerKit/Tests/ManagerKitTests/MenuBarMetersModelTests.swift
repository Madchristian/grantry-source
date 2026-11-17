import Foundation
import Observation
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

    // MARK: - Tafel der Übersicht (Baukasten #503)

    private static let all = Set(TaskManagerSource.allCases)

    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private func stored() throws -> [String: Any] {
        let data = try #require(settings.object(forKey: MenuBarMetersModel.storageKey) as? Data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func store(_ json: String) {
        settings.set(Data(json.utf8), forKey: MenuBarMetersModel.storageKey)
    }

    /// Erster Start: der Standard, wie die Karten aus #495.
    @Test func boardStartsWithTheStandard() {
        let model = model()
        #expect(model.overviewLayout == .standard(configured: Self.all))
        #expect(model.overviewPlacements == model.overviewLayout.placements())
    }

    /// Ausgeblendete Karten aus #495 bleiben ausgeblendet; „Last und Laufzeit“ sind zwei Kacheln. `hiddenCards` bleibt
    /// für ältere Versionen gespeichert, und bloßes Lesen schreibt nichts.
    @Test func hiddenCardsAreMigratedAndKept() throws {
        store(#"{"shown":["overview"],"styles":{},"showsTags":true,"hiddenCards":["gpu","summary"]}"#)
        let model = model()
        #expect(model.overviewLayout == OverviewBoardLayout(migratingHiddenCards: [.gpu, .summary], configured: Self.all))
        #expect(!model.overviewLayout.contains(.uptime))
        #expect(try stored()["overviewLayout"] == nil)
        model.showsTags = false
        #expect(try Set(stored()["hiddenCards"] as? [String] ?? []) == ["gpu", "summary"])
    }

    @Test func changedBoardIsRememberedNextToHiddenCards() throws {
        store(#"{"shown":[],"styles":{},"showsTags":true,"hiddenCards":["gpu"]}"#)
        let model = model()
        let board = OverviewBoardLayout(tiles: [OverviewTile(.memory, .large), OverviewTile(.cpu, .small)])
        model.setOverviewLayout(board)
        #expect(model.overviewLayout == board)
        #expect(self.model().overviewLayout == board)
        #expect(try stored()["hiddenCards"] as? [String] == ["gpu"])
    }

    /// Am Mac ohne Akku fehlt die Kachel im Standard und in einer gespeicherten Anordnung.
    @Test func boardLeavesOutTilesWithoutSource() {
        let configured = Self.all.subtracting([.battery])
        #expect(!model(configured: configured).overviewLayout.contains(.battery))
        model().setOverviewLayout(OverviewBoardLayout(tiles: [OverviewTile(.battery, .small), OverviewTile(.cpu, .wide)]))
        #expect(model(configured: configured).overviewLayout.tiles == [OverviewTile(.cpu, .wide)])
    }

    /// Eine Anordnung einer neueren Version zeigt den Standard und bleibt gespeichert, bis Christian die Tafel ändert –
    /// auch wenn sich andere Einstellungen ändern.
    @Test func unreadableBoardShowsStandardAndIsKeptUntilChanged() throws {
        store(#"{"shown":["cpu"],"styles":{},"showsTags":true,"overviewLayout":{"version":2,"tiles":[{"kind":"cpu","span":"8x1"}],"neu":[true,1.5,null]}}"#)
        let model = model()
        #expect(model.isShown(.cpu))
        #expect(model.overviewLayout == .standard(configured: Self.all))
        model.showsTags = false
        let kept = try #require(try stored()["overviewLayout"] as? [String: Any])
        #expect(kept["version"] as? Int == 2)
        #expect((kept["neu"] as? [Any])?.count == 3)
        model.setOverviewLayout(OverviewBoardLayout(tiles: [OverviewTile(.cpu, .small)]))
        #expect(self.model().overviewLayout.tiles == [OverviewTile(.cpu, .small)])
    }

    /// Die Lage rechnet das Modell nur bei geänderter Anordnung, nicht bei anderen Einstellungen.
    @Test func placementsChangeOnlyWithTheBoard() {
        let model = model()
        let changed = Flag()
        withObservationTracking { _ = model.overviewPlacements } onChange: { changed.isSet = true }
        model.showsTags = false
        model.setStyle(.bar, for: .cpu)
        #expect(!changed.isSet)
        var board = model.overviewLayout
        board.remove(.cores)
        model.setOverviewLayout(board)
        #expect(changed.isSet)
        #expect(model.overviewPlacements == board.placements())
    }

    /// Offenes Popover misst nur die Quellen der Kacheln auf der Tafel; ändert sich die Tafel, folgt die Auswahl.
    @Test func openBoardMeasuresOnlyItsTiles() async {
        let model = model()
        model.setOverviewLayout(OverviewBoardLayout(tiles: [OverviewTile(.processes, .large), OverviewTile(.uptime, .small)]))
        model.beginOverviewMeasurement()
        #expect(taskManager.isRunning)
        #expect(taskManager.selectedSources == [.processes])
        model.setOverviewLayout(OverviewBoardLayout(tiles: [OverviewTile(.gpu, .wide)]))
        #expect(taskManager.selectedSources == [.gpu])
        model.endOverviewMeasurement()
        #expect(!taskManager.isRunning)
        await taskManager.stopAndWait()
    }

    /// Popover und Editor in den Einstellungen teilen den Abnehmer: Erst wenn beide zu sind, endet die Messung.
    @Test func boardMeasuresUntilTheLastViewerCloses() async {
        let model = model()
        model.beginOverviewMeasurement()
        model.beginOverviewMeasurement()
        model.endOverviewMeasurement()
        #expect(taskManager.isRunning)
        model.endOverviewMeasurement()
        model.endOverviewMeasurement()
        #expect(!taskManager.isRunning)
        model.beginOverviewMeasurement()
        #expect(taskManager.isRunning)
        await taskManager.stopAndWait()
    }

    // MARK: - Übernahme vom Stand 2026.11.14 (Build 1791, vor dem Baukasten)

    /// Einstellungen, wie 2026.11.14 sie schreibt: Elemente, Darstellungen, Kurzbezeichnung und ausgeblendete Karten,
    /// keine Tafel.
    private static func settings20261114(hidden: [String]) -> String {
        let cards = hidden.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"shown\":[\"overview\",\"cpu\",\"memory\"],\"styles\":{\"cpu\":\"numberAndGraph\",\"memory\":\"bar\"},"
            + "\"showsTags\":false,\"hiddenCards\":[\(cards)]}"
    }

    /// So liest 2026.11.14 die Einstellungen (`MenuBarMeterSettings` vor dem Baukasten): unbekannte Felder wie die
    /// Tafel übergeht es.
    private struct Settings20261114: Decodable {
        let shown: Set<MenuBarMeterKind>
        let styles: [MenuBarMeterKind: MenuBarMeterStyle]
        let showsTags: Bool
        let hiddenCards: Set<MenuBarOverviewCard>?
    }

    /// Ohne ausgeblendete Karten zeigt die Tafel nach dem Update den Standard, der dem bisherigen Popover entspricht; die
    /// übrigen Einstellungen gelten weiter, und bloßes Lesen schreibt nichts.
    @Test func overviewOf20261114BecomesTheStandard() throws {
        store(Self.settings20261114(hidden: []))
        let model = model()
        #expect(model.overviewLayout == .standard(configured: Self.all))
        #expect(MenuBarMeterKind.allCases.filter(model.isShown) == [.overview, .cpu, .memory])
        #expect(model.style(for: .cpu) == .numberAndGraph)
        #expect(model.style(for: .memory) == .bar)
        #expect(!model.showsTags)
        #expect(try stored()["overviewLayout"] == nil)
        #expect(try stored()["hiddenCards"] as? [String] == [])
    }

    /// Wer die Übersicht in 2026.11.14 nie angepasst hat, bekommt nach dem Update genau die Standard-Tafel der Abnahme
    /// vom 16.11.2026 (neun Zeilen, Datenträger und Netz 2 x 2), auch nach weiteren Starts und geänderten Einstellungen;
    /// gespeichert wird keine Tafel, solange er sie nicht ändert.
    @Test func untouchedOverviewOf20261114GetsExactlyTheStandardBoard() throws {
        store(Self.settings20261114(hidden: []))
        let expected = [OverviewTile(.cpu, .banner), OverviewTile(.cores, .banner), OverviewTile(.processes, .panel),
                        OverviewTile(.gpu, .large), OverviewTile(.memory, .large), OverviewTile(.disk, .large),
                        OverviewTile(.network, .large), OverviewTile(.thermal, .small), OverviewTile(.battery, .small),
                        OverviewTile(.loadAverage, .small), OverviewTile(.uptime, .small)]
        let model = model()
        #expect(model.overviewLayout.tiles == expected)
        #expect(OverviewBoardLayout.grid.rowCount(of: model.overviewPlacements) == 9)
        model.showsTags = true
        model.setStyle(.bar, for: .cpu)
        #expect(self.model().overviewLayout.tiles == expected)
        #expect(try stored()["overviewLayout"] == nil)
    }

    /// Wer in 2026.11.14 Karten ausgeblendet hatte, behält das über weitere Starts und geänderte Einstellungen hinweg;
    /// die Tafel kommt jedes Mal aus den gespeicherten Karten und kehrt nicht zum Standard zurück.
    @Test func hiddenCardsOf20261114StayHiddenAcrossLaunches() throws {
        store(Self.settings20261114(hidden: ["gpu", "summary"]))
        let first = model().overviewLayout
        let model = model()
        model.showsTags = true
        model.setStyle(.bar, for: .cpu)
        let later = self.model().overviewLayout
        #expect(later == first)
        #expect(later != .standard(configured: Self.all))
        #expect([OverviewTileKind.gpu, .loadAverage, .uptime].allSatisfy { !later.contains($0) })
        #expect(try Set(stored()["hiddenCards"] as? [String] ?? []) == ["gpu", "summary"])
        #expect(try stored()["overviewLayout"] == nil)
    }

    /// Ausgeblendete Karten von 2026.11.14 fehlen auf der Tafel, die übrigen behalten ihre Größe aus dem Standard und
    /// rücken ohne Lücken nach (dichte Packung); „Last und Laufzeit“ fehlt als zwei Kacheln.
    @Test func hiddenCardsOf20261114StayHidden() {
        store(Self.settings20261114(hidden: ["gpu", "processes", "summary", "battery"]))
        let board = model().overviewLayout
        #expect(board.tiles == [OverviewTile(.cpu, .banner), OverviewTile(.cores, .banner), OverviewTile(.memory, .large),
                                OverviewTile(.disk, .large), OverviewTile(.network, .large), OverviewTile(.thermal, .small)])
        let anchors = board.placements().map { [$0.anchor.column, $0.anchor.row] }
        #expect(anchors == [[0, 0], [0, 1], [0, 2], [2, 2], [0, 4], [2, 4]])
    }

    /// Ändert Christian die Tafel, bleibt alles von 2026.11.14 gespeichert, auch die ausgeblendeten Karten: Ein Wechsel
    /// zurück auf 2026.11.14 findet seine Einstellungen unverändert vor.
    @Test func settingsOf20261114SurviveAChangedBoard() throws {
        store(Self.settings20261114(hidden: ["gpu", "summary"]))
        let model = model()
        var board = model.overviewLayout
        board.remove(.cores)
        model.setOverviewLayout(board)
        #expect(self.model().overviewLayout == board)
        let data = try #require(settings.object(forKey: MenuBarMetersModel.storageKey) as? Data)
        let older = try JSONDecoder().decode(Settings20261114.self, from: data)
        #expect(older.shown == [.overview, .cpu, .memory])
        #expect(older.styles == [.cpu: .numberAndGraph, .memory: .bar])
        #expect(!older.showsTags)
        #expect(older.hiddenCards == [.gpu, .summary])
        #expect(try stored()["overviewLayout"] != nil)
    }

    /// Einstellungen aus der Zeit vor der Übersicht kennen keine Karten; sie bleiben trotzdem lesbar.
    @Test func settingsWithoutCardsStayReadable() {
        settings.set(Data(#"{"shown":["cpu"],"styles":{"cpu":"bar"},"showsTags":false}"#.utf8),
                     forKey: MenuBarMetersModel.storageKey)
        let model = model()
        #expect(model.isShown(.cpu))
        #expect(model.style(for: .cpu) == .bar)
        #expect(!model.showsTags)
        #expect(model.overviewLayout == .standard(configured: Self.all))
    }

    @Test func unreadableSettingsFallBackToDefaults() {
        settings.set(Data("kaputt".utf8), forKey: MenuBarMetersModel.storageKey)
        settings.set(true, forKey: MenuBarMetersModel.legacyStorageKey)
        let model = model()
        #expect(MenuBarMeterKind.allCases.filter(model.isShown) == [.overview])
        #expect(model.showsTags)
    }
}
