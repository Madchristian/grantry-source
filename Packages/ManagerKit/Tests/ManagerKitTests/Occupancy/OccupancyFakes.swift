import Darwin
import Foundation
import Synchronization
import TestSupport
@testable import ManagerKit

/// Dateisystem im Speicher für den Belegungsscanner: Ordner, Dateien, Hardlinks, Symlinks, Einhängepunkte, gesperrte und
/// nur in der Cloud liegende Ordner. Pfade relativ zur Wurzel (`"Library/Caches"`, `""` für die Wurzel). Zeichnet
/// gelesene Ordner, gleichzeitige Leser und die Thread-Einstellungen der Leser auf.
final class FakeOccupancyFileSystem: OccupancyFileSystem {
    /// E/A-Drosselung, Nachladen von iCloud-Platzhaltern und CPU-Priorität des lesenden Threads.
    struct ReaderPolicy: Hashable, Sendable {
        let diskPolicy: Int32
        let datalessPolicy: Int32
        let priority: Int32

        static var current: ReaderPolicy {
            ReaderPolicy(
                diskPolicy: getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD),
                datalessPolicy: getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD),
                priority: currentPriority()
            )
        }

        /// Was der Scanner verlangt: gedrosselt, ohne Nachladen, Priorität eines Threads mit QoS utility.
        static var throttledUtility: ReaderPolicy {
            ReaderPolicy(diskPolicy: IOPOL_THROTTLE, datalessPolicy: IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
                         priority: utilityPriority)
        }

        /// Priorität, die der Kernel einem Thread mit QoS utility gibt – gemessen an einem eigenen Thread.
        static let utilityPriority: Int32 = {
            let result = Mutex<Int32>(-1)
            let done = DispatchSemaphore(value: 0)
            Thread {
                pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
                result.withLock { $0 = currentPriority() }
                done.signal()
            }.start()
            done.wait()
            return result.withLock { $0 }
        }()

        /// Basispriorität des aufrufenden Threads (`THREAD_EXTENDED_INFO`).
        private static func currentPriority() -> Int32 {
            var info = thread_extended_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
            let thread = pthread_mach_thread_np(pthread_self())
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? info.pth_priority : -1
        }
    }

    private enum Entry {
        case file(identity: FileIdentity, bytes: Int64, links: Int, modification: Int64)
        case directory
        case symlink
        case mountPoint(isLocal: Bool)
        case unstatable
    }

    private struct Folder {
        var identity: FileIdentity
        var modification: Int64
        var isReadable = true
        var isDataless = false
    }

    private struct State {
        var folders: [String: Folder] = [:]
        var contents: [String: [String: Entry]] = [:]
        var nextInode: UInt64 = 100
        var reads: [String] = []
        var active = 0
        var maximumActive = 0
        var policies: Set<ReaderPolicy> = []
        var vanishing: Set<String> = []
        var onRead: (@Sendable (String) -> Void)?
    }

    let rootPath: String
    let device: Int32
    /// Wurzeln auf einem Netzlaufwerk (`root(at:)` wirft `networkVolume`).
    let networkRoots: Set<String>
    private let state = Mutex(State())

    init(rootPath: String = "/fake/home", device: Int32 = 1, networkRoots: Set<String> = []) {
        self.rootPath = rootPath
        self.device = device
        self.networkRoots = networkRoots
        state.withLock { state in
            state.folders[rootPath] = Folder(identity: FileIdentity(device: device, inode: 2, type: .directory), modification: 1)
            state.contents[rootPath] = [:]
        }
    }

    func path(_ relative: String) -> String {
        relative.isEmpty ? rootPath : rootPath + "/" + relative
    }

    // MARK: Aufbau

    func addFolder(_ relative: String, modification: Int64 = 1, device: Int32? = nil, isReadable: Bool = true,
                   isDataless: Bool = false) {
        state.withLock { state in
            let path = path(relative)
            Self.ensureParents(of: path, root: rootPath, device: self.device, in: &state)
            let identity = FileIdentity(device: device ?? self.device, inode: Self.inode(&state), type: .directory)
            state.folders[path] = Folder(identity: identity, modification: modification, isReadable: isReadable,
                                         isDataless: isDataless)
            state.contents[path, default: [:]] = state.contents[path] ?? [:]
            Self.insert(.directory, at: path, in: &state)
        }
    }

    /// Reguläre Datei; mit `inode` und `links` > 1 ein Hardlink auf dieselbe Datei an mehreren Orten.
    func addFile(_ relative: String, bytes: Int64, inode: UInt64? = nil, links: Int = 1, modification: Int64 = 1) {
        state.withLock { state in
            let path = path(relative)
            Self.ensureParents(of: path, root: rootPath, device: device, in: &state)
            let identity = FileIdentity(device: device, inode: inode ?? Self.inode(&state), type: .regularFile)
            Self.insert(.file(identity: identity, bytes: bytes, links: links, modification: modification), at: path, in: &state)
        }
    }

    func addSymlink(_ relative: String) {
        insert(.symlink, at: relative)
    }

    /// Einhängepunkt, den das echte Dateisystem aus der Mount-Tabelle erkennt (ohne `stat`).
    func addMountPoint(_ relative: String, isLocal: Bool) {
        insert(.mountPoint(isLocal: isLocal), at: relative)
    }

    /// Eintrag, dessen `stat` scheitert (der Ordner gilt dann als unvollständig gelesen).
    func addUnstatableEntry(_ relative: String) {
        insert(.unstatable, at: relative)
    }

    func remove(_ relative: String) {
        state.withLock { state in
            let path = path(relative)
            let parent = (path as NSString).deletingLastPathComponent
            state.contents[parent]?[(path as NSString).lastPathComponent] = nil
            for key in state.folders.keys where key == path || key.hasPrefix(path + "/") {
                state.folders[key] = nil
                state.contents[key] = nil
            }
        }
    }

    func setModification(of relative: String, to modification: Int64) {
        state.withLock { $0.folders[path(relative)]?.modification = modification }
    }

    func setReadable(_ relative: String, _ isReadable: Bool) {
        state.withLock { $0.folders[path(relative)]?.isReadable = isReadable }
    }

    /// Ersetzt den Ordner durch einen anderen mit neuer Identität (gleicher Inhalt).
    func replaceFolder(_ relative: String) {
        state.withLock { state in
            let inode = Self.inode(&state)
            guard let folder = state.folders[path(relative)] else { return }
            state.folders[path(relative)]?.identity = FileIdentity(device: folder.identity.device, inode: inode, type: .directory)
        }
    }

    /// Der Ordner verschwindet zwischen dem Lesen seines Elternordners und seinem eigenen.
    func makeVanish(_ relative: String) {
        state.withLock { _ = $0.vanishing.insert(path(relative)) }
    }

    /// Läuft bei jedem gelesenen Ordner, bevor er geliefert wird (auf dem Leser-Thread).
    func onRead(_ hook: (@Sendable (String) -> Void)?) {
        state.withLock { $0.onRead = hook }
    }

    // MARK: Aufzeichnung

    /// Gelesene Ordner (absolute Pfade) in Lesereihenfolge.
    var reads: [String] { state.withLock { $0.reads } }

    func resetReads() {
        state.withLock { $0.reads = [] }
    }

    var maximumConcurrentReads: Int { state.withLock { $0.maximumActive } }

    var readerPolicies: Set<ReaderPolicy> { state.withLock { $0.policies } }

    // MARK: OccupancyFileSystem

    func root(at path: String) throws(OccupancyScanError) -> OccupancyRoot {
        if networkRoots.contains(path) { throw .networkVolume }
        guard path == rootPath, let folder = state.withLock({ $0.folders[rootPath] }) else { throw .unavailable }
        return OccupancyRoot(path: rootPath, identity: folder.identity, modification: folder.modification, mountPoints: [:])
    }

    func readDirectory(
        at path: String, expected: FileIdentity, in root: OccupancyRoot, isCancelled: () -> Bool,
        visit: (OccupancyEntry) -> Void
    ) -> OccupancyReadOutcome {
        let policy = ReaderPolicy.current
        let (hook, isVanishing) = state.withLock { state in
            state.reads.append(path)
            state.active += 1
            state.maximumActive = max(state.maximumActive, state.active)
            state.policies.insert(policy)
            return (state.onRead, state.vanishing.contains(path))
        }
        defer { state.withLock { $0.active -= 1 } }
        hook?(path)
        let (folder, contents, folders) = state.withLock { ($0.folders[path], $0.contents[path] ?? [:], $0.folders) }
        guard let folder, !isVanishing else { return .vanished }
        guard folder.identity == expected else { return .uncaptured(.changed) }
        guard folder.isReadable else { return .uncaptured(.permissionDenied) }
        guard !folder.isDataless else { return .cloudOnly }
        for (name, entry) in contents.sorted(by: { $0.key < $1.key }) {
            if isCancelled() { return .cancelled }
            switch entry {
            case .file(let identity, let bytes, let links, let modification):
                visit(.file(name: name, identity: identity, allocatedBytes: bytes, linkCount: links, modification: modification))
            case .directory:
                guard let child = folders[path + "/" + name] else { continue }
                visit(.directory(name: name, identity: child.identity, modification: child.modification,
                                 isDataless: child.isDataless))
            case .symlink:
                visit(.other(name: name, modification: 1))
            case .mountPoint(let isLocal):
                visit(.mountPoint(name: name, isLocal: isLocal))
            case .unstatable:
                visit(.unreadable(name: name))
            }
        }
        return .read(isComplete: true)
    }

    // MARK: Hilfen

    private func insert(_ entry: Entry, at relative: String) {
        state.withLock { state in
            let path = path(relative)
            Self.ensureParents(of: path, root: rootPath, device: device, in: &state)
            Self.insert(entry, at: path, in: &state)
        }
    }

    private static func insert(_ entry: Entry, at path: String, in state: inout State) {
        let parent = (path as NSString).deletingLastPathComponent
        state.contents[parent, default: [:]][(path as NSString).lastPathComponent] = entry
    }

    private static func inode(_ state: inout State) -> UInt64 {
        defer { state.nextInode += 1 }
        return state.nextInode
    }

    private static func ensureParents(of path: String, root: String, device: Int32, in state: inout State) {
        var missing: [String] = []
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > root.count, state.folders[parent] == nil {
            missing.append(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        for folder in missing.reversed() {
            let identity = FileIdentity(device: device, inode: inode(&state), type: .directory)
            state.folders[folder] = Folder(identity: identity, modification: 1)
            state.contents[folder] = [:]
            insert(.directory, at: folder, in: &state)
        }
    }
}

/// Änderungsprotokoll zum Vorgeben: `mark` zählt die Ereignis-ID hoch, `changes` liefert, was der Test meldet.
final class FakeOccupancyJournal: OccupancyChangeJournal {
    private struct State {
        var eventID: UInt64 = 0
        var isAvailable = true
        var changes: OccupancyChanges? = OccupancyChanges()
        var calls: [String] = []
        var queriedMarks: [OccupancyChangeMark] = []
    }

    private let state = Mutex(State())

    /// Was der nächste `changes(since:)` meldet; `nil` heißt „nicht sicher, voller Scan“.
    func report(_ changes: OccupancyChanges?) {
        state.withLock { $0.changes = changes }
    }

    /// Ohne Journal (etwa ein Volume ohne FSEvents-Verlauf) gibt es keine Marke.
    func setAvailable(_ isAvailable: Bool) {
        state.withLock { $0.isAvailable = isAvailable }
    }

    /// Aufrufe in Reihenfolge: `mark`, `changes`.
    var calls: [String] { state.withLock { $0.calls } }

    var queriedMarks: [OccupancyChangeMark] { state.withLock { $0.queriedMarks } }

    func mark(forDevice device: Int32) -> OccupancyChangeMark? {
        state.withLock { state in
            state.calls.append("mark")
            state.eventID += 1
            return state.isAvailable ? OccupancyChangeMark(journal: "fake", eventID: state.eventID) : nil
        }
    }

    func changes(since mark: OccupancyChangeMark, under root: String, device: Int32) async -> OccupancyChanges? {
        state.withLock { state in
            state.calls.append("changes")
            state.queriedMarks.append(mark)
            return state.changes
        }
    }
}

/// Wartet, bis `parties` Threads angekommen sind, höchstens `timeout`; danach laufen alle weiter.
final class ThreadBarrier: Sendable {
    private let parties: Int
    private let arrived = Mutex(0)
    private let semaphore = DispatchSemaphore(value: 0)

    init(parties: Int) {
        self.parties = parties
    }

    func arriveAndWait(timeout: TimeInterval = 5) {
        let count = arrived.withLock { count in
            count += 1
            return count
        }
        if count == parties {
            for _ in 1..<parties { semaphore.signal() }
        } else if count < parties {
            _ = semaphore.wait(timeout: .now() + timeout)
        }
    }
}

extension OccupancyScanner {
    /// Scanner über dem Fake-Dateisystem.
    static func testing(
        _ fileSystem: FakeOccupancyFileSystem, journal: FakeOccupancyJournal = FakeOccupancyJournal(),
        clock: TestClock? = nil, excluded: Set<String> = []
    ) -> OccupancyScanner {
        guard let clock else { return OccupancyScanner(fileSystem: fileSystem, journal: journal, excluded: excluded) }
        return OccupancyScanner(fileSystem: fileSystem, journal: journal, clock: clock, excluded: excluded)
    }
}
