import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Einstellbare Uhr (ein `Mutex` lässt sich nicht in escaping Closures einfangen).
private final class ManualDate: Sendable {
    private let storage: Mutex<Date>

    init(_ date: Date) { storage = Mutex(date) }

    var now: Date { storage.withLock { $0 } }

    func advance(by seconds: TimeInterval) { storage.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppUsageModelTests {
    /// 2026-11-06 10:00 UTC.
    private let clock = ManualDate(Date(timeIntervalSince1970: 1_793_959_200))

    /// Symlinkfreier Ordner je Test (`PrivateDirectory` öffnet ohne Symlink-Auflösung).
    private func withStore(_ body: (AppUsageStore) throws -> Void) throws {
        try ScratchDirectory.withCanonical(prefix: "app-usage-model") { scratch in
            try body(AppUsageStore(url: scratch.appending(path: "Grantry/AppUsageHistory.json")))
        }
    }

    private func model(_ store: AppUsageStore) -> AppUsageModel {
        let clock = clock
        return AppUsageModel(store: store, now: { clock.now })
    }

    private func advance(by seconds: TimeInterval) {
        clock.advance(by: seconds)
    }

    private static let frame: TaskManagerFrame = {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [ProcessMeasurement(key: ProcessKey(pid: 2_001, startTime: 1), parentPID: 1, uid: 501,
                                                 name: "claude", cpuLoad: 0.5, memoryBytes: 1, diskReadPerSecond: nil,
                                                 diskWritePerSecond: nil, threadCount: 1, energyMilliwatts: 2_000)]
        return TaskManagerFrame(snapshot: snapshot, history: SampleHistory(interval: .seconds(1)), elapsed: .seconds(1))
    }()

    private func record(_ model: AppUsageModel) {
        model.record(Self.frame, apps: [], currentUID: 501, network: nil)
    }

    @Test func recordsInMemoryAndWritesOnlyAfterFlushInterval() throws {
        try withStore { store in
            let model = model(store)
            model.load()
            record(model)
            #expect(model.history.hours.count == 1)
            try #expect(store.load().isEmpty)
            advance(by: AppUsageModel.flushInterval)
            record(model)
            try #expect(store.load().hours.first?.measuredSeconds == 2)
        }
    }

    @Test func framesWithinFlushIntervalNeverTouchTheDisk() throws {
        try withStore { store in
            let model = model(store)
            model.load()
            for _ in 0..<100 {
                advance(by: 1)
                record(model)
            }
            #expect(model.history.hours.first?.measuredSeconds == 100)
            #expect(!FileManager.default.fileExists(atPath: store.url.deletingLastPathComponent().path))
        }
    }

    @Test func clearAlsoRemovesLeftoversOfInterruptedWrites() throws {
        try withStore { store in
            let model = model(store)
            record(model)
            model.flush()
            let rest = store.url.deletingLastPathComponent().appending(path: ".AppUsageHistory.json.\(UUID().uuidString)")
            try Data("Rest".utf8).write(to: rest)
            model.clear()
            #expect(!FileManager.default.fileExists(atPath: rest.path))
            #expect(model.lastError == nil)
        }
    }

    @Test func flushWritesPendingData() throws {
        try withStore { store in
            let model = model(store)
            record(model)
            model.flush()
            try #expect(store.load() == model.history)
            #expect(model.lastError == nil)
        }
    }

    @Test func newHourWritesImmediately() throws {
        try withStore { store in
            advance(by: 3_420)
            let model = model(store)
            model.load()
            advance(by: 120)
            record(model)
            try #expect(store.load().isEmpty)
            advance(by: 120)
            record(model)
            try #expect(store.load().hours.count == 2)
        }
    }

    @Test func loadReadsSavedHistoryOnce() throws {
        try withStore { store in
            let first = model(store)
            record(first)
            first.flush()
            let second = model(store)
            #expect(second.history.isEmpty)
            second.load()
            #expect(second.history == first.history)
        }
    }

    @Test func clearRemovesFileAndMemory() throws {
        try withStore { store in
            let model = model(store)
            record(model)
            model.flush()
            model.clear()
            #expect(model.history.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            model.flush()
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
        }
    }

    @Test func failedWriteIsReported() throws {
        // Ein Symlink im Pfad: `PrivateDirectory` lehnt ab, der Fehler landet in `lastError`, nichts stürzt ab.
        let model = model(AppUsageStore(url: FileManager.default.temporaryDirectory
            .appending(path: "app-usage-\(UUID().uuidString)/AppUsageHistory.json")))
        record(model)
        model.flush()
        #expect(model.lastError != nil)
    }

    // MARK: - Unlesbare Datei (#353)

    private func placeDamagedFile(at store: AppUsageStore) throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("kein JSON".utf8).write(to: store.url)
    }

    @Test func damagedFileIsSetAsideWithVisibleNotice() throws {
        try withStore { store in
            try placeDamagedFile(at: store)
            let model = model(store)
            model.load()
            #expect(model.history.isEmpty)
            let notice = try #require(model.lastError)
            #expect(notice.contains("beiseitegelegt"))
            record(model)
            model.flush()
            #expect(model.lastError == notice)
            try #expect(store.load() == model.history)
            model.clear()
            #expect(model.lastError == nil)
        }
    }

    @Test func retentionCheckReportsDamagedFile() throws {
        try withStore { store in
            try placeDamagedFile(at: store)
            let model = model(store)
            model.enforceRetention()
            #expect(model.lastError != nil)
        }
    }

    /// Lässt sich die unlesbare Datei nicht beiseitelegen, schreibt das Modell nie darüber – auch nicht, wenn der Ordner
    /// später wieder beschreibbar ist; erst „Verlauf löschen“ gibt das Speichern frei.
    @Test func fileThatCannotBeSetAsideIsNeverOverwritten() throws {
        try withStore { store in
            try placeDamagedFile(at: store)
            let folder = store.url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            let model = model(store)
            model.load()
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let notice = try #require(model.lastError)
            record(model)
            model.flush()
            #expect(try String(contentsOf: store.url, encoding: .utf8) == "kein JSON")
            #expect(model.lastError == notice)
            model.clear()
            record(model)
            model.flush()
            try #expect(store.load() == model.history)
            #expect(model.lastError == nil)
        }
    }

    // MARK: - Aufbewahrung (30 Tage) auch ohne neue Takte

    private static let oldTool = AppUsageSubject(kind: .process, bundleID: nil, name: "old-tool", bundlePath: nil)
    private static let freshTool = AppUsageSubject(kind: .process, bundleID: nil, name: "fresh-tool", bundlePath: nil)

    /// Legt die Datei mit je einer Stunde im Alter `ages` (Tage vor `clock`) an: ab 30 Tagen von „old-tool“, sonst von
    /// „fresh-tool“, beide weit über der Kleinstverbrauchs-Schwelle.
    private func seed(_ store: AppUsageStore, daysAgo ages: [Double]) throws {
        var history = AppUsageHistory()
        for age in ages {
            let subject = age > 30 ? Self.oldTool : Self.freshTool
            let used = AppUsageTotals(cpuSeconds: 30, energyJoules: 100, networkBytes: 0, diskBytes: 0)
            history.add(AppUsageSample(end: clock.now.addingTimeInterval(-age * 86_400), seconds: 60,
                                       measuresNetwork: false, usage: [(subject, used)]))
        }
        try store.save(history)
    }

    private func fileText(_ store: AppUsageStore) throws -> String {
        String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
    }

    /// Setzt die Änderungszeit auf einen alten Stempel; ein erneutes (atomares) Schreiben der Datei änderte ihn.
    private func stampFile(_ store: AppUsageStore) throws -> Date {
        let stamp = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: store.url.path)
        return stamp
    }

    private func modificationDate(_ store: AppUsageStore) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: store.url.path)[.modificationDate] as? Date
    }

    @Test func enforceRetentionDropsExpiredHoursWithoutNewFrames() throws {
        try withStore { store in
            try seed(store, daysAgo: [31, 1])
            let model = model(store)
            model.enforceRetention()
            let kept = try store.load()
            #expect(kept.hours.map(\.start) == [AppUsageHistory.hourStart(of: clock.now.addingTimeInterval(-86_400))])
            #expect(Array(kept.subjects.keys) == [Self.freshTool.id])
            #expect(!(try fileText(store)).contains("old-tool"))
            #expect(model.lastError == nil)
        }
    }

    @Test func enforceRetentionRemovesFileAndLeftoversWhenNothingIsLeft() throws {
        try withStore { store in
            try seed(store, daysAgo: [31, 40])
            let rest = store.url.deletingLastPathComponent().appending(path: ".AppUsageHistory.json.\(UUID().uuidString)")
            try Data("Rest".utf8).write(to: rest)
            let model = model(store)
            model.enforceRetention()
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            #expect(!FileManager.default.fileExists(atPath: rest.path))
            #expect(model.lastError == nil)
        }
    }

    @Test func enforceRetentionWithoutFileCreatesNothing() throws {
        try withStore { store in
            let model = model(store)
            model.enforceRetention()
            #expect(!FileManager.default.fileExists(atPath: store.url.deletingLastPathComponent().path))
            #expect(model.history.isEmpty)
            #expect(model.lastError == nil)
        }
    }

    @Test func enforceRetentionLeavesFreshHistoryUntouchedAndUnloaded() throws {
        try withStore { store in
            try seed(store, daysAgo: [2, 1])
            let stamp = try stampFile(store)
            let model = model(store)
            model.enforceRetention()
            #expect(try modificationDate(store) == stamp)
            #expect(model.history.isEmpty)
        }
    }

    @Test func enforceRetentionKeepsStoredHoursForLaterRecording() throws {
        try withStore { store in
            try seed(store, daysAgo: [31, 1])
            let model = model(store)
            model.enforceRetention()
            record(model)
            model.flush()
            try #expect(store.load().hours.count == 2)
        }
    }

    @Test func enforceRetentionAlsoPrunesAnAlreadyLoadedHistory() throws {
        try withStore { store in
            try seed(store, daysAgo: [29.5, 0.5])
            let model = model(store)
            model.load()
            #expect(model.history.hours.count == 2)
            advance(by: 2 * 86_400)
            model.enforceRetention()
            #expect(model.history.hours.count == 1)
            try #expect(store.load() == model.history)
        }
    }

    @Test func loadOfExpiredHoursCountsAsChangeAndFlushWritesIt() throws {
        try withStore { store in
            try seed(store, daysAgo: [31, 1])
            let model = model(store)
            model.load()
            #expect(model.history.hours.count == 1)
            model.flush()
            try #expect(store.load().hours.count == 1)
            #expect(!(try fileText(store)).contains("old-tool"))
        }
    }

    @Test func flushRemovesFileWhenLoadLeftNothing() throws {
        try withStore { store in
            try seed(store, daysAgo: [31])
            let model = model(store)
            model.load()
            #expect(model.history.isEmpty)
            model.flush()
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            #expect(model.lastError == nil)
        }
    }

    @Test func loadOfFreshHistoryDoesNotRewriteTheFile() throws {
        try withStore { store in
            try seed(store, daysAgo: [2, 1])
            let stamp = try stampFile(store)
            let model = model(store)
            model.load()
            model.flush()
            #expect(try modificationDate(store) == stamp)
        }
    }

    @Test func taskManagerModelHandsEveryFrameToObserver() async throws {
        let frames = Recorder<Int>()
        let memory = MemoryStatus(physicalBytes: 16, usedBytes: 8, swapUsedBytes: nil, swapTotalBytes: nil,
                                  pressure: .normal, processCount: 0)
        let taskManager = TaskManagerModel(sources: TaskManagerSources(memory: ScriptedMetricSource(readings: [memory])),
                                           clock: TestClock(), failures: SourceFailureLog(report: { _, _ in }))
        taskManager.onFrame = { frame in frames.append(frame.snapshot.memory == nil ? 0 : 1) }
        taskManager.start(for: .window)
        let deadline = ContinuousClock.now + .seconds(10)
        while frames.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(frames.values.first == 1)
        await taskManager.stopAndWait()
    }
}
