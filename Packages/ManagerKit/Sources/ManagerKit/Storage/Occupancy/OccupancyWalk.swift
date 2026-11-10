import Darwin
import Foundation
import Synchronization

/// Ein Durchlauf des Belegungsscanners auf eigenen Leser-Threads (QoS utility, E/A gedrosselt, ohne iCloud-Nachladen).
///
/// Jeder Leser holt einen Ordner vom gemeinsamen Stapel, liest ihn und legt die Unterordner nach. Beim erneuten Scan
/// (`previous` und `plan` gesetzt) entscheidet `action(for:previous:modification:plan:)` je Ordner: unveränderte
/// Unterbäume als dieselben Datensätze übernehmen, nur die Einträge eines unveränderten Ordners übernehmen und tiefer
/// steigen, oder neu lesen. Ergebnisse landen in Fächern je Ordner-ID; am Ende setzt der letzte Leser sie zum Baum
/// zusammen – ebenfalls außerhalb des kooperativen Pools.
final class OccupancyWalk: Sendable {
    struct Configuration: Sendable {
        let fileSystem: any OccupancyFileSystem
        let root: OccupancyRoot
        /// Wurzel des letzten Scans derselben Wurzel (dieselbe Identität); nur zusammen mit `plan`.
        let previous: OccupancyRecord?
        let plan: OccupancyRescanPlan?
        let mark: OccupancyChangeMark?
        let excluded: Set<String>
        let largestFileCount: Int
    }

    /// Was mit einem Ordner geschieht.
    private enum Action: Sendable {
        /// Lesen; `previous` dient dem Vergleich seiner Unterordner.
        case read(previous: OccupancyRecord?)
        /// Unverändert: Einträge übernehmen, Unterordner einzeln entscheiden.
        case descend(OccupancyRecord)
        /// Unverändert samt Unterbaum.
        case reuse(OccupancyRecord)
    }

    private struct Pending: Sendable {
        let id: Int
        let parent: Int?
        let path: String
        let name: String
        let identity: FileIdentity
        let modification: OccupancyTimestamp?
        let action: Action
    }

    /// Ergebnis je Ordner-ID.
    private enum Slot: Sendable {
        /// Gelesen oder übernommen; die Unterordner liegen in eigenen Fächern.
        case listed(parent: Int?, Listing)
        /// Fertig samt Unterbaum (übernommen, Einhängepunkt, nicht erfassbar).
        case finished(parent: Int?, OccupancyRecord)
    }

    private struct Listing: Sendable {
        let name: String
        let identity: FileIdentity?
        let modification: OccupancyTimestamp?
        let state: OccupancyFolderState
        let files: OccupancyDirectFiles
    }

    private let configuration: Configuration
    private let progress: OccupancyProgressReporter
    private let cpuBudget = OccupancyCPUBudget(elapsed: OccupancyProgressReporter.stopwatch(ContinuousClock()))
    private let stack: OccupancyWorkStack<Pending>
    private let slots = Mutex<[Slot?]>([])
    private let nextID = Atomic(1)
    private let isCancelled = Atomic(false)
    private let finishedReaders = Atomic(0)

    init(_ configuration: Configuration, progress: OccupancyProgressReporter) {
        self.configuration = configuration
        self.progress = progress
        let root = configuration.root
        let name = root.path.split(separator: "/").last.map(String.init) ?? root.path
        stack = OccupancyWorkStack([Pending(
            id: 0, parent: nil, path: root.path, name: name, identity: root.identity, modification: root.modification,
            action: Self.action(for: root.path, previous: configuration.previous, modification: root.modification,
                                plan: configuration.plan)
        )])
    }

    /// Liest mit `readers` Threads bis zum Ende; wirft `CancellationError` nach dem Abbruch des Tasks und
    /// `OccupancyScanError.unavailable`, wenn die Wurzel verschwunden ist.
    func run(readers: Int) async throws -> OccupancyTree {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                for _ in 0..<readers {
                    let thread = Thread { [self] in
                        Self.prepareCurrentThread()
                        readUntilDone()
                        if finishedReaders.add(1, ordering: .acquiringAndReleasing).newValue == readers {
                            continuation.resume(with: result())
                        }
                    }
                    thread.name = "\(ManagerKit.logSubsystem).occupancy"
                    thread.start()
                }
            }
        } onCancel: {
            isCancelled.store(true, ordering: .relaxed)
            stack.stop()
        }
    }

    /// CPU-Priorität von QoS utility (`BASEPRI_UTILITY` im Kernel).
    static let utilityPriority: Int32 = 20

    /// E/A gedrosselt (`IOPOL_THROTTLE`), iCloud-Platzhalter werden nicht nachgeladen (ihr Lesen scheitert mit
    /// `EDEADLK`), CPU-Priorität wie QoS utility. Eine E/A-Policy je Thread nimmt den Thread aus der QoS-Verwaltung
    /// (gemessen: QoS danach „nicht angegeben“, Priorität 31 statt 20, `pthread_set_qos_class_self_np` scheitert); die
    /// Priorität von utility wird deshalb danach direkt gesetzt. Die Leser-Threads gehören dem Durchlauf und enden mit
    /// ihm – zurückgesetzt wird nichts.
    private static func prepareCurrentThread() {
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        var policy: Int32 = 0, parameters = sched_param()
        guard pthread_getschedparam(pthread_self(), &policy, &parameters) == 0 else { return }
        parameters.sched_priority = utilityPriority
        pthread_setschedparam(pthread_self(), policy, &parameters)
    }

    private func readUntilDone() {
        var cpuTime = Self.threadCPUTime()
        while let item = stack.next() {
            let more = isCancelled.load(ordering: .relaxed) ? [] : process(item)
            stack.complete(adding: more)
            let now = Self.threadCPUTime()
            let pause = cpuBudget.charge(now - cpuTime)
            cpuTime = now
            if pause > .zero, !isCancelled.load(ordering: .relaxed) { Thread.sleep(forTimeInterval: pause / .seconds(1)) }
        }
    }

    /// Rechenzeit des aufrufenden Threads.
    private static func threadCPUTime() -> Duration {
        .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))
    }

    private func result() -> Result<OccupancyTree, any Error> {
        guard !isCancelled.load(ordering: .relaxed) else { return .failure(CancellationError()) }
        guard let root = assemble() else { return .failure(OccupancyScanError.unavailable) }
        return .success(OccupancyTree(rootPath: configuration.root.path, root: root, mark: configuration.mark))
    }

    // MARK: Ordner

    private func process(_ item: Pending) -> [Pending] {
        switch item.action {
        case .reuse(let record):
            store(.finished(parent: item.parent, record), at: item.id)
            return []
        case .descend(let record):
            store(.listed(parent: item.parent, Listing(name: record.name, identity: record.identity,
                                                      modification: record.modification, state: record.state,
                                                      files: record.files)), at: item.id)
            return record.children.compactMap { child in pending(for: child, below: item) }
        case .read(let previous):
            return read(item, previous: previous)
        }
    }

    private func read(_ item: Pending, previous: OccupancyRecord?) -> [Pending] {
        let configuration = configuration
        var files = OccupancyDirectFiles()
        if let modification = item.modification { files.noteModification(modification) }
        var directories: [(name: String, identity: FileIdentity, modification: OccupancyTimestamp, isDataless: Bool)] = []
        var mountPoints: [OccupancyRecord] = []
        var isComplete = true
        let outcome = configuration.fileSystem.readDirectory(
            at: item.path, expected: item.identity, in: configuration.root,
            isCancelled: { isCancelled.load(ordering: .relaxed) }
        ) { entry in
            switch entry {
            case .file(let name, let identity, let allocatedBytes, let linkCount, let modification):
                files.add(name: name, identity: identity, allocatedBytes: allocatedBytes, linkCount: linkCount,
                          limit: configuration.largestFileCount)
                files.noteModification(modification)
            case .directory(let name, let identity, let modification, let isDataless):
                directories.append((name, identity, modification, isDataless))
                files.noteModification(modification)
            case .mountPoint(let name, let isLocal):
                mountPoints.append(OccupancyRecord(name: name, identity: nil, modification: nil,
                                                   state: .otherVolume(isLocal: isLocal)))
            case .other(_, let modification):
                files.noteModification(modification)
            case .unreadable:
                isComplete = false
            }
        }
        switch outcome {
        case .cancelled, .vanished:
            return []
        case .uncaptured(let gap):
            store(.finished(parent: item.parent, leaf(item, state: .uncaptured(gap))), at: item.id)
            return []
        case .cloudOnly:
            store(.finished(parent: item.parent, leaf(item, state: .cloudOnly)), at: item.id)
            return []
        case .read(let isReadComplete):
            progress.add(folders: 1, files: files.count, bytes: files.allocatedBytes)
            let state: OccupancyFolderState = isReadComplete && isComplete ? .complete : .uncaptured(.incomplete)
            store(.listed(parent: item.parent, Listing(name: item.name, identity: item.identity,
                                                      modification: item.modification, state: state, files: files)),
                  at: item.id)
            for mountPoint in mountPoints { store(.finished(parent: item.id, mountPoint), at: makeID()) }
            return directories.compactMap { directory in
                pending(named: directory.name, identity: directory.identity, modification: directory.modification,
                        isDataless: directory.isDataless, below: item, previous: previous?.child(named: directory.name))
            }
        }
    }

    /// Unterordner aus einer frischen Liste: andere Volumes, iCloud-Platzhalter und Ausgenommenes werden nicht betreten.
    private func pending(
        named name: String, identity: FileIdentity, modification: OccupancyTimestamp, isDataless: Bool, below parent: Pending,
        previous: OccupancyRecord?
    ) -> Pending? {
        let path = parent.path + "/" + name
        let root = configuration.root
        let state: OccupancyFolderState? = if identity.device != root.identity.device {
            .otherVolume(isLocal: root.mountPoints[path] ?? true)
        } else if isDataless {
            .cloudOnly
        } else if configuration.excluded.contains(path) {
            .uncaptured(.excluded)
        } else {
            nil
        }
        let id = makeID()
        if let state {
            store(.finished(parent: parent.id, OccupancyRecord(name: name, identity: identity, modification: modification,
                                                               state: state)), at: id)
            return nil
        }
        let previous = previous.flatMap { $0.identity == identity ? $0 : nil }
        return Pending(id: id, parent: parent.id, path: path, name: name, identity: identity, modification: modification,
                       action: Self.action(for: path, previous: previous, modification: modification, plan: configuration.plan))
    }

    /// Unterordner eines unveränderten Ordners: ohne frische Liste zählt, was der letzte Scan wusste. Andere Volumes und
    /// Platzhalter bleiben, wie sie waren – eine Änderung daran meldet das Protokoll am Elternordner, der dann neu
    /// gelesen wird. Ausgenommenes bleibt es, solange es ausgenommen ist.
    private func pending(for child: OccupancyRecord, below parent: Pending) -> Pending? {
        let path = parent.path + "/" + child.name
        let id = makeID()
        if configuration.excluded.contains(path) {
            let excluded = child.state == .uncaptured(.excluded) ? child
                : OccupancyRecord(name: child.name, identity: child.identity, modification: child.modification,
                                  state: .uncaptured(.excluded))
            store(.finished(parent: parent.id, excluded), at: id)
            return nil
        }
        guard let identity = child.identity, child.state == .complete || child.state.isUncaptured else {
            store(.finished(parent: parent.id, child), at: id)
            return nil
        }
        return Pending(id: id, parent: parent.id, path: path, name: child.name, identity: identity,
                       modification: child.modification,
                       action: Self.action(for: path, previous: child, modification: nil, plan: configuration.plan))
    }

    /// Entscheidung für einen Ordner, den der letzte Scan als `previous` kannte (dieselbe Identität). `modification` ist
    /// sein frisches Änderungsdatum, falls der Elternordner gerade gelesen wurde. Nicht erfassbare Ordner werden immer
    /// neu versucht (etwa nach dem Erteilen des Festplattenvollzugriffs), unvollständig gelesene samt Vergleich ihrer
    /// Unterordner.
    private static func action(
        for path: String, previous: OccupancyRecord?, modification: OccupancyTimestamp?, plan: OccupancyRescanPlan?
    ) -> Action {
        guard let plan, let previous, !plan.isSubtreeChanged(path) else { return .read(previous: nil) }
        switch previous.state {
        case .complete: break
        case .uncaptured(.incomplete): return .read(previous: previous)
        default: return .read(previous: nil)
        }
        if let modification, modification != previous.modification { return .read(previous: previous) }
        if plan.isListingChanged(path) { return .read(previous: previous) }
        if plan.hasChanges(atOrBelow: path) || previous.uncapturedCount > 0 { return .descend(previous) }
        return .reuse(previous)
    }

    private func leaf(_ item: Pending, state: OccupancyFolderState) -> OccupancyRecord {
        OccupancyRecord(name: item.name, identity: item.identity, modification: item.modification, state: state)
    }

    // MARK: Fächer

    private func makeID() -> Int {
        nextID.add(1, ordering: .relaxed).oldValue
    }

    private func store(_ slot: Slot, at id: Int) {
        slots.withLock { slots in
            if slots.count <= id { slots.append(contentsOf: repeatElement(nil, count: id - slots.count + 1)) }
            slots[id] = slot
        }
    }

    /// Setzt die Fächer zum Baum zusammen: Unterordner haben größere IDs als ihr Elternordner, von hinten nach vorn
    /// sind sie also fertig, wenn der Elternordner an der Reihe ist. Verschwundene Ordner haben kein Fach.
    private func assemble() -> OccupancyRecord? {
        let slots = slots.withLock { slots in
            defer { slots = [] }
            return slots
        }
        var children = [[OccupancyRecord]](repeating: [], count: slots.count)
        var root: OccupancyRecord?
        for id in slots.indices.reversed() {
            guard let slot = slots[id] else { continue }
            let (parent, record): (Int?, OccupancyRecord)
            switch slot {
            case .finished(let owner, let finished):
                (parent, record) = (owner, finished)
            case .listed(let owner, let listing):
                let sorted = children[id].sorted { $0.name < $1.name }
                children[id] = []
                (parent, record) = (owner, OccupancyRecord(
                    name: listing.name, identity: listing.identity, modification: listing.modification,
                    state: listing.state, files: listing.files, children: sorted
                ))
            }
            if let parent { children[parent].append(record) } else { root = record }
        }
        return root
    }
}

/// Hält die Rechenzeit der Leser im Mittel bei höchstens `coreShare` eines Kerns (Spec § 4.4: Scan ≤ 100 % eines Kerns).
/// Zwei Leser überbrücken die Wartezeit der gedrosselten E/A (gemessen: halbe Dauer bei gleicher Rechenzeit); rechnen sie
/// zusammen mehr, pausiert der Leser, der die Grenze überschreitet, um den Überhang.
final class OccupancyCPUBudget: Sendable {
    /// Anteil eines Kerns für die Leser. Gemessen wird Grantry als Ganzes (Abnahme: ≤ 103 %); neben den Lesern arbeiten
    /// Ansicht, Bedienungshilfen und Hintergrund. Mit einem vollen Kern lag der Scan in der Abnahme 2026.11.10-1547 bei
    /// 106 % (Leser 90 %, Main-Thread 13 %); 90 % lassen der übrigen App Platz (#530).
    static let coreShare = 0.9
    /// Spielraum, damit nicht schon die ersten Ordner Pausen auslösen.
    static let allowance: Duration = .milliseconds(200)
    /// Längste Pause am Stück; danach wird neu gerechnet.
    static let maximumPause: Duration = .milliseconds(100)

    private let elapsed: @Sendable () -> Duration
    private let used = Mutex(Duration.zero)

    init(elapsed: @escaping @Sendable () -> Duration) {
        self.elapsed = elapsed
    }

    /// Verbucht `cpu` Rechenzeit eines Lesers; liefert die Pause, die er danach einlegen soll.
    func charge(_ cpu: Duration) -> Duration {
        let total = used.withLock { used in
            used += cpu
            return used
        }
        let excess = total - elapsed() * Self.coreShare - Self.allowance
        return excess > .zero ? min(excess, Self.maximumPause) : .zero
    }
}

/// Meldet den Fortschritt höchstens einmal je `interval` (Spec § 4.4: höchstens viermal je Sekunde; Grantry meldet ihn
/// einmal je Sekunde, `OccupancyScanner.progressInterval`).
final class OccupancyProgressReporter: Sendable {
    private struct State {
        var progress = OccupancyProgress()
        var lastReport: Duration = .zero
    }

    private let interval: Duration
    private let elapsed: @Sendable () -> Duration
    private let report: @Sendable (OccupancyProgress) -> Void
    private let state = Mutex(State())

    init(interval: Duration, elapsed: @escaping @Sendable () -> Duration,
         report: @escaping @Sendable (OccupancyProgress) -> Void) {
        self.interval = interval
        self.elapsed = elapsed
        self.report = report
    }

    /// Stoppuhr ab jetzt auf `clock`.
    static func stopwatch(_ clock: some Clock<Duration>) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    func add(folders: Int, files: Int, bytes: Int64) {
        let now = elapsed()
        // Unter der Sperre gemeldet: So kommen die Meldungen in Reihenfolge an; es sind höchstens vier je Sekunde.
        state.withLock { state in
            state.progress.folders += folders
            state.progress.files += files
            state.progress.allocatedBytes += bytes
            guard now - state.lastReport >= interval else { return }
            state.lastReport = now
            report(state.progress)
        }
    }
}
