import Foundation
import Observation

/// Zustand der Ansicht „Belegung“ (TM-15.4, #403; Spec 2026-11-08 § 5.4): Scan auf Abruf über `OccupancyStore`,
/// Navigation in der Ordnerleiter, Volumes und Datenträger, Time-Machine-Status des gewählten Ordners. Nur lesend.
///
/// Leistung (Spec § 4.4): kein Takt. Der Fortschritt kommt einmal je Sekunde vom Scanner; Volumes werden beim
/// Öffnen (höchstens einmal je Minute) und nach jedem Scan gelesen, der Time-Machine-Status je gewähltem Ordner einmal.
/// Verdeckt hält das Modell den Baum nicht fest: Der Speicher verwirft ihn 10 min später, beim Öffnen kommt er von dort.
@MainActor
@Observable
public final class OccupancyModel {
    static let inventoryRefresh: TimeInterval = 60

    public private(set) var state: OccupancyState

    @ObservationIgnored private let store: OccupancyStore
    @ObservationIgnored private let loadInventory: @Sendable () async -> VolumeInventory
    @ObservationIgnored private let makeHints: @Sendable (StorageCatalog.Configuration) -> OccupancyHints
    @ObservationIgnored private let configuration: @MainActor () -> StorageCatalog.Configuration
    @ObservationIgnored private let timeMachineStatus: @Sendable (String) async -> TimeMachineFolderStatus
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var inventoryLoadedAt: Date?
    @ObservationIgnored private var isLoadingInventory = false
    @ObservationIgnored private var pendingTimeMachine: Set<String> = []
    @ObservationIgnored private var isVisible = false
    /// Aufbau der Hinweise (liest wenige Ordnerlisten) und Summen über den Baum außerhalb des Hauptthreads.
    @ObservationIgnored private let work = BlockingWorkQueue(label: "occupancy-model")

    /// Mit den Quellen des Systems; die Orte der Speicher-Kategorien folgen den Einstellungen von Speicher (Code-Ordner).
    public convenience init(preferences: StoragePreferences) {
        let inventory = VolumeInventorySource(), exclusions = TimeMachineExclusions()
        self.init(home: NSHomeDirectory(), store: OccupancyStore(), inventory: { await inventory.inventory() },
                  hints: { OccupancyHints(configuration: $0) }, configuration: { preferences.catalogConfiguration },
                  timeMachineStatus: { await exclusions.status(of: $0) }, now: { Date() })
    }

    init(home: String, store: OccupancyStore, inventory: @escaping @Sendable () async -> VolumeInventory,
         hints: @escaping @Sendable (StorageCatalog.Configuration) -> OccupancyHints,
         configuration: @escaping @MainActor () -> StorageCatalog.Configuration,
         timeMachineStatus: @escaping @Sendable (String) async -> TimeMachineFolderStatus,
         now: @escaping @Sendable () -> Date) {
        state = OccupancyState(home: home)
        self.store = store
        loadInventory = inventory
        makeHints = hints
        self.configuration = configuration
        self.timeMachineStatus = timeMachineStatus
        self.now = now
    }

    /// - Parameter findings: Befunde der Lagezeile (`TaskManagerModel.findings`) für den Befund-Punkt.
    public func presentation(findings: [SystemFinding] = []) -> OccupancyPresentation {
        OccupancyPresentation(state, findings: findings, now: now())
    }

    /// Wurzel des Scans: der Benutzerordner oder das Datenvolume.
    var rootPath: String { state.scope == .home ? state.home : MountedVolume.dataVolumePrefix }

    // MARK: Sichtbarkeit

    /// Die Ansicht ist zu sehen: Ergebnis aus dem Speicher holen, Volumes lesen, falls älter als eine Minute.
    public func appear() {
        isVisible = true
        let store = store
        Task {
            await store.setVisible(true)
            await self.restore()
        }
        refreshInventory(force: false)
    }

    /// Verdeckt: Der Speicher beginnt die Frist bis zum Verwerfen; das Modell gibt den Baum frei.
    public func disappear() {
        isVisible = false
        let store = store
        Task { await store.setVisible(false) }
        state.tree = nil
        state.cleanable = nil
    }

    public func setFullDiskAccessMissing(_ isMissing: Bool) {
        guard state.isFullDiskAccessMissing != isMissing else { return }
        state.isFullDiskAccessMissing = isMissing
    }

    /// Anderer Umfang: Das bisherige Ergebnis gilt nicht mehr.
    public func setScope(_ scope: OccupancyScope) {
        guard scope != state.scope, state.phase != .scanning else { return }
        state.scope = scope
        resetResult()
        let store = store
        Task { await store.discard() }
    }

    // MARK: Scan

    public func scan() {
        guard state.phase != .scanning else { return }
        let root = rootPath, store = store, makeHints = makeHints, configuration = configuration()
        let excluded = state.isFullDiskAccessMissing
            ? OccupancyProtectedPlaces.folders(inHome: state.home, scanRoot: root) : Set<String>()
        let previousPath = currentPath
        let started = now()
        state.phase = .scanning
        state.progress = nil
        let report: @Sendable (OccupancyProgress) -> Void = { progress in
            Task { @MainActor [weak self] in self?.report(progress) }
        }
        scanTask = Task { [weak self, work] in
            do {
                let tree = try await store.scan(root, excluding: excluded, progress: report)
                let result = await work.run {
                    let hints = makeHints(configuration)
                    let excludedPlaces = tree.uncapturedFolders().filter { $0.state == .uncaptured(.excluded) }.count
                    return (hints, hints.cleanable(in: tree), excludedPlaces)
                }
                self?.finish(tree, hints: result.0, cleanable: result.1, excludedPlaces: result.2, started: started,
                             path: previousPath)
            } catch is CancellationError {
                self?.stopScanning()
            } catch OccupancyScanError.networkVolume {
                self?.fail("Die Wurzel liegt auf einem Netzlaufwerk; Netzlaufwerke liest Grantry nicht.")
            } catch OccupancyScanError.busy {
                self?.fail("Es läuft bereits ein Scan.")
            } catch {
                self?.fail("Der Ordner ist nicht verfügbar.")
            }
        }
    }

    public func cancel() {
        scanTask?.cancel()
        scanTask = nil
        stopScanning()
    }

    private func report(_ progress: OccupancyProgress) {
        guard state.phase == .scanning else { return }
        state.progress = progress
    }

    private func finish(_ tree: OccupancyTree, hints: OccupancyHints, cleanable: OccupancyCleanable, excludedPlaces: Int,
                        started: Date, path: String?) {
        guard state.phase == .scanning else { return }
        state.phase = .done
        state.progress = nil
        state.hints = hints
        state.excludedPlaces = excludedPlaces
        state.scannedAt = now()
        state.scanDuration = .seconds(now().timeIntervalSince(started))
        state.timeMachine = [:]
        pendingTimeMachine = []
        state.trail = path.map { Self.trail(to: $0, in: tree) } ?? []
        state.selection = nil
        if isVisible {
            state.tree = tree
            state.cleanable = cleanable
            refreshTimeMachine()
        }
        refreshInventory(force: true)
    }

    private func stopScanning() {
        guard state.phase == .scanning else { return }
        state.phase = state.scannedAt == nil ? .idle : .done
        state.progress = nil
    }

    private func fail(_ reason: String) {
        guard state.phase == .scanning else { return }
        state.phase = .failed(reason)
        state.progress = nil
    }

    private func resetResult() {
        state.phase = .idle
        state.tree = nil
        state.cleanable = nil
        state.trail = []
        state.selection = nil
        state.timeMachine = [:]
        state.excludedPlaces = 0
        state.scannedAt = nil
        state.scanDuration = nil
        pendingTimeMachine = []
    }

    /// Holt das gehaltene Ergebnis zurück; ist es inzwischen verworfen, beginnt die Ansicht von vorn.
    private func restore() async {
        guard isVisible, state.tree == nil, state.phase != .scanning, state.scannedAt != nil else { return }
        guard let tree = await store.tree, tree.rootPath == rootPath else {
            resetResult()
            return
        }
        let hints = state.hints, cleanable = await work.run { hints?.cleanable(in: tree) }
        guard isVisible, state.tree == nil else { return }
        state.tree = tree
        state.cleanable = cleanable
        refreshTimeMachine()
    }

    // MARK: Navigation

    /// Zeile gewählt: mit Unterordnern hinabsteigen, sonst im Detail zeigen.
    public func select(_ rowID: Int) {
        guard let navigation = OccupancyNavigation(state) else { return }
        if let folder = navigation.subfolders.first(where: { $0.id == rowID }), folder.subfolderCount > 0,
           folder.state == .complete || folder.state.isUncaptured {
            state.trail.append(folder.id)
            state.selection = nil
        } else if rowID != OccupancyPresentation.moreRowID {
            state.selection = rowID
        }
        refreshTimeMachine()
    }

    /// Zurück zur Stufe `depth` (0: Wurzel).
    public func ascend(to depth: Int) {
        guard depth >= 0, depth < state.trail.count + 1 else { return }
        state.trail = Array(state.trail.prefix(depth))
        state.selection = nil
        refreshTimeMachine()
    }

    /// Pfad des Ordners, in dem man steht (Schreibweise des Baums).
    var currentPath: String? {
        OccupancyNavigation(state).map { $0.tree.path(of: $0.current) }
    }

    /// Ordner im Detail (Firmlink-Schreibweise) für den Finder; `nil` ohne Ergebnis.
    public var focusedPath: String? { presentation().detail?.path }

    /// Weg zu `path` im (neuen) Baum, so weit er noch existiert.
    static func trail(to path: String, in tree: OccupancyTree) -> [Int] {
        guard var folder = tree.folder(atPath: path) else {
            let parent = (path as NSString).deletingLastPathComponent
            return parent.count < path.count && parent.count >= tree.rootPath.count ? trail(to: parent, in: tree) : []
        }
        var trail: [Int] = []
        while let parent = tree.parent(of: folder) {
            trail.append(folder.id)
            folder = parent
        }
        return trail.reversed()
    }

    // MARK: Nachladen

    private func refreshInventory(force: Bool) {
        guard !isLoadingInventory else { return }
        if !force, let loaded = inventoryLoadedAt, now().timeIntervalSince(loaded) < Self.inventoryRefresh { return }
        isLoadingInventory = true
        let loadInventory = loadInventory
        Task { [weak self] in
            let inventory = await loadInventory()
            guard let self else { return }
            self.isLoadingInventory = false
            self.inventoryLoadedAt = self.now()
            self.state.inventory = inventory
        }
    }

    /// Time-Machine-Status des Ordners im Detail, einmal je Pfad und Scan.
    private func refreshTimeMachine() {
        guard let navigation = OccupancyNavigation(state), navigation.selection != OccupancyPresentation.filesRowID else { return }
        let folder = navigation.focused ?? navigation.current
        guard folder.state == .complete || folder.allocatedBytes > 0 else { return }
        let path = navigation.tree.path(of: folder)
        guard state.timeMachine[path] == nil, pendingTimeMachine.insert(path).inserted else { return }
        let timeMachineStatus = timeMachineStatus
        Task { [weak self] in
            let status = await timeMachineStatus(path)
            guard let self, self.pendingTimeMachine.remove(path) != nil else { return }
            self.state.timeMachine[path] = status
        }
    }
}
