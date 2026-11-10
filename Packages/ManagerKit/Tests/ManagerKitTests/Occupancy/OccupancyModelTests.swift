import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Modell der Ansicht „Belegung“ (TM-15.4, #403): Scan auf Abruf, Ausnahmen ohne Festplattenvollzugriff, Navigation,
/// Abbruch, Freigabe des Baums beim Verdecken, Time-Machine-Status einmal je Ordner.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct OccupancyModelTests {
    private let fileSystem = OccupancyPresentationTests.fileSystem()
    private let timeMachineQueries = Recorder<String>()

    private func makeModel(store: OccupancyStore? = nil) -> OccupancyModel {
        let queries = timeMachineQueries
        return OccupancyModel(
            home: fileSystem.rootPath,
            store: store ?? OccupancyStore(scanner: .testing(fileSystem), clock: TestClock()),
            inventory: { OccupancyPresentationTests.inventory() },
            hints: { _ in OccupancyPresentationTests.hints() },
            configuration: { StorageCatalog.Configuration(home: "/fake/home", codeRoots: [], minimumAgeDays: 30) },
            timeMachineStatus: { path in
                queries.append(path)
                return TimeMachineFolderStatus(state: .included, excludedFolder: nil)
            },
            now: { OccupancyPresentationTests.now })
    }

    private func scanned(_ model: OccupancyModel) async {
        model.appear()
        model.scan()
        while model.state.phase == .scanning || model.state.tree == nil || model.state.inventory == nil {
            await Task.yield()
        }
    }

    private func id(_ model: OccupancyModel, _ relative: String) throws -> Int {
        try #require(model.state.tree?.folder(atPath: fileSystem.path(relative))).id
    }

    @Test func scanBuildsTheResultWithHintsAndVolumes() async throws {
        let model = makeModel()
        await scanned(model)

        #expect(model.state.phase == .done)
        #expect(model.state.cleanable?.total == 13 * OccupancyPresentationTests.gigabyte)
        #expect(model.state.excludedPlaces == 0)
        #expect(model.state.scannedAt == OccupancyPresentationTests.now)
        #expect(model.presentation().volumes.first?.parts.map(\.id) == ["rest", "home", "cleanable", "purgeable"])
    }

    @Test func withoutFullDiskAccessTheProtectedPlacesAreLeftOut() async throws {
        let model = makeModel()
        model.setFullDiskAccessMissing(true)
        await scanned(model)

        let documents = try #require(model.state.tree?.folder(atPath: fileSystem.path("Documents")))
        #expect(documents.state == .uncaptured(.excluded))
        #expect(model.state.excludedPlaces == 1)
        #expect(model.presentation().ladder.offersFullDiskAccess)
    }

    @Test func selectingDescendsAndAscendingGoesBack() async throws {
        let model = makeModel()
        await scanned(model)

        model.select(try id(model, "Library"))
        model.select(try id(model, "Library/Caches"))
        #expect(model.presentation().ladder.steps.map(\.title) == ["Benutzerordner", "Library", "Caches"])
        #expect(model.presentation().detail?.title == "Caches")

        // Ohne Unterordner: wählen statt hinabsteigen.
        let app = try id(model, "Library/Caches/app")
        model.select(app)
        #expect(model.state.selection == app)
        #expect(model.presentation().ladder.steps.count == 3)
        #expect(model.presentation().detail?.title == "app")

        model.ascend(to: 1)
        #expect(model.presentation().ladder.steps.map(\.title) == ["Benutzerordner", "Library"])
        #expect(model.state.selection == nil)
        model.ascend(to: 0)
        #expect(model.state.trail.isEmpty)
    }

    @Test func rescanKeepsThePlaceInTheLadder() async throws {
        let model = makeModel()
        await scanned(model)
        model.select(try id(model, "Library"))
        model.select(try id(model, "Library/Caches"))

        fileSystem.addFile("Library/Caches/new/x", bytes: 1_000)
        model.scan()
        while model.state.phase == .scanning { await Task.yield() }

        #expect(model.presentation().ladder.steps.map(\.title) == ["Benutzerordner", "Library", "Caches"])
    }

    @Test func timeMachineIsAskedOncePerFolder() async throws {
        let model = makeModel()
        await scanned(model)
        let library = try id(model, "Library")
        model.select(library)
        while model.state.timeMachine[fileSystem.path("Library")] == nil { await Task.yield() }
        model.ascend(to: 0)
        model.select(library)
        for _ in 0..<20 { await Task.yield() }

        #expect(timeMachineQueries.values.filter { $0 == fileSystem.path("Library") }.count == 1)
        #expect(model.presentation().detail?.hints.last?.status.text == "wird gesichert")
    }

    @Test func hidingReleasesTheTreeAndShowingRestoresIt() async throws {
        let model = makeModel()
        await scanned(model)
        model.select(try id(model, "Library"))

        model.disappear()
        #expect(model.state.tree == nil)
        model.appear()
        while model.state.tree == nil { await Task.yield() }
        #expect(model.presentation().ladder.steps.map(\.title) == ["Benutzerordner", "Library"])
        #expect(model.state.cleanable?.total == 13 * OccupancyPresentationTests.gigabyte)
    }

    @Test func discardedResultStartsOver() async throws {
        let store = OccupancyStore(scanner: .testing(fileSystem), clock: TestClock())
        let model = makeModel(store: store)
        await scanned(model)
        model.disappear()
        await store.discard()

        model.appear()
        while model.state.phase != .idle { await Task.yield() }
        #expect(model.state.scannedAt == nil)
        #expect(model.presentation().items.first?.text == "Noch nicht gescannt")
    }

    @Test func cancelReturnsToTheStateBefore() async throws {
        let held = Latch()
        fileSystem.onRead { _ in held.wait() }
        let model = makeModel()
        model.appear()
        model.scan()
        #expect(model.state.phase == .scanning)
        model.cancel()
        held.release(1_000)

        #expect(model.state.phase == .idle)
        #expect(model.presentation().bar.isScanning == false)
    }

    @Test func changingTheScopeDropsTheResult() async throws {
        let model = makeModel()
        await scanned(model)

        model.setScope(.volume)
        #expect(model.state.scope == .volume)
        #expect(model.state.tree == nil)
        #expect(model.state.phase == .idle)
        #expect(model.rootPath == MountedVolume.dataVolumePrefix)
    }

    @Test func trailFollowsAPathIntoANewTree() async throws {
        let tree = try await OccupancyScanner.testing(fileSystem).scan(fileSystem.rootPath)
        let caches = try #require(tree.folder(atPath: fileSystem.path("Library/Caches")))
        #expect(OccupancyModel.trail(to: fileSystem.path("Library/Caches"), in: tree).last == caches.id)
        // Verschwunden: so weit, wie der Weg noch besteht.
        #expect(OccupancyModel.trail(to: fileSystem.path("Library/Caches/gone/deeper"), in: tree).last == caches.id)
        #expect(OccupancyModel.trail(to: "/elsewhere", in: tree).isEmpty)
    }
}
