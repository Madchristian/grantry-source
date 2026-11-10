import Darwin
import Testing
@testable import ManagerKit

@Suite struct ProcessUsageSamplerTests {
    private static let own = KernelProcess(pid: 42, parentPID: 1, uid: 501, startTime: 7, command: "Brows")
    private static let foreign = KernelProcess(pid: 88, parentPID: 1, uid: 0, startTime: 9, command: "WindowServer")
    private static let usage = ResourceUsage(cpuTimeNanoseconds: 5, diskBytesRead: 6, diskBytesWritten: 7,
                                            memoryBytes: 8, threadCount: 9)

    private func sampler(_ processes: [KernelProcess], usageCalls: Recorder<pid_t> = Recorder(),
                         path: String? = "/Applications/Browser.app/Contents/MacOS/Browser") -> ProcessUsageSampler {
        ProcessUsageSampler(currentUID: 501, processes: { processes },
                            usage: { usageCalls.append($0); return Self.usage }, executablePath: { _ in path })
    }

    @Test func ownProcessCarriesCountersAndPath() throws {
        let counters = try #require(try sampler([Self.own]).read().first)
        #expect(counters.key == ProcessKey(pid: 42, startTime: 7))
        #expect(counters.name == "Browser")
        #expect(counters.cpuTimeNanoseconds == 5)
        #expect(counters.diskBytesRead == 6)
        #expect(counters.diskBytesWritten == 7)
        #expect(counters.memoryBytes == 8)
        #expect(counters.threadCount == 9)
        #expect(counters.executablePath == "/Applications/Browser.app/Contents/MacOS/Browser")
    }

    @Test func foreignProcessHasNeitherCountersNorPath() throws {
        let calls = Recorder<pid_t>()
        let counters = try #require(try sampler([Self.foreign], usageCalls: calls).read().first)
        #expect(counters.name == "WindowServer")
        #expect(counters.cpuTimeNanoseconds == nil)
        #expect(counters.memoryBytes == nil)
        #expect(counters.executablePath == nil)
        #expect(calls.values.isEmpty)
    }

    @Test func nameFallsBackToKernelCommand() throws {
        #expect(try sampler([Self.own], path: nil).read().first?.name == "Brows")
        #expect(ProcessUsageSampler.name(command: "a\nb", executablePath: nil) == "a b")
    }

    @Test func pathIsReadOncePerProcessGeneration() throws {
        let reborn = KernelProcess(pid: 42, parentPID: 1, uid: 501, startTime: 8, command: "Brows")
        let listing = ScriptedMetricSource<[KernelProcess]>(readings: [[Self.own], [Self.own, Self.foreign], [reborn]])
        let paths = Recorder<pid_t>()
        let sampler = ProcessUsageSampler(currentUID: 501, processes: { try listing.read() }, usage: { _ in Self.usage },
                                          executablePath: { paths.append($0); return "/Applications/Browser.app/Contents/MacOS/Browser" })
        #expect(try sampler.read().first?.name == "Browser")
        #expect(try sampler.read().first?.executablePath == "/Applications/Browser.app/Contents/MacOS/Browser")
        #expect(paths.values == [42])
        _ = try sampler.read()
        #expect(paths.values == [42, 42])
    }

    @Test func execReadsThePathAgain() throws {
        let execed = KernelProcess(pid: 42, parentPID: 1, uid: 501, startTime: 7, command: "zsh")
        let listing = ScriptedMetricSource<[KernelProcess]>(readings: [[Self.own], [execed]])
        let paths = Recorder<pid_t>()
        let sampler = ProcessUsageSampler(currentUID: 501, processes: { try listing.read() }, usage: { _ in Self.usage },
                                          executablePath: { pid in
                                              paths.append(pid)
                                              return paths.values.count == 1 ? "/Applications/Browser.app/Contents/MacOS/Browser" : "/bin/zsh"
                                          })
        #expect(try sampler.read().first?.name == "Browser")
        #expect(try sampler.read().first?.name == "zsh")
        #expect(paths.values.count == 2)
    }

    /// Verschwundene Prozesse bleiben nicht im Cache: Taucht dieselbe Generation nach einer Lesung ohne sie wieder auf,
    /// wird der Pfad neu gelesen.
    @Test func vanishedProcessLeavesTheCache() throws {
        let listing = ScriptedMetricSource<[KernelProcess]>(readings: [[Self.own], [], [Self.own]])
        let paths = Recorder<pid_t>()
        let sampler = ProcessUsageSampler(currentUID: 501, processes: { try listing.read() }, usage: { _ in Self.usage },
                                          executablePath: { paths.append($0); return "/bin/zsh" })
        _ = try sampler.read()
        _ = try sampler.read()
        #expect(paths.values == [42])
        _ = try sampler.read()
        #expect(paths.values == [42, 42])
    }

    @Test func cachedProgramStillCarriesCountersOfEveryRead() throws {
        let readings = [ResourceUsage(cpuTimeNanoseconds: 1, diskBytesRead: 2, diskBytesWritten: 3, memoryBytes: 4,
                                      threadCount: 5, energyNanojoules: 6),
                        ResourceUsage(cpuTimeNanoseconds: 10, diskBytesRead: 20, diskBytesWritten: 30, memoryBytes: 40,
                                      threadCount: 50, energyNanojoules: 60)]
        let usage = ScriptedMetricSource<ResourceUsage>(readings: readings)
        let sampler = ProcessUsageSampler(currentUID: 501, processes: { [Self.own] }, usage: { _ in try? usage.read() },
                                          executablePath: { _ in "/bin/zsh" })
        let first = try #require(try sampler.read().first)
        let second = try #require(try sampler.read().first)
        #expect([first.cpuTimeNanoseconds, second.cpuTimeNanoseconds] == [1, 10])
        #expect([first.energyNanojoules, second.energyNanojoules] == [6, 60])
        #expect([first.executablePath, second.executablePath] == ["/bin/zsh", "/bin/zsh"])
        #expect(second.name == "zsh")
    }

    @Test func listingErrorPropagates() {
        let sampler = ProcessUsageSampler(currentUID: 501, processes: { throw ProcessTableError(code: EPERM) },
                                          usage: { _ in nil }, executablePath: { _ in nil })
        #expect(throws: ProcessTableError(code: EPERM)) { try sampler.read() }
    }

    @Test func machTicksBecomeNanoseconds() {
        #expect(ProcessUsageSampler.nanoseconds(ticks: 3, numer: 125, denom: 3) == 125)
        #expect(ProcessUsageSampler.nanoseconds(ticks: 1_000, numer: 1, denom: 1) == 1_000)
        #expect(ProcessUsageSampler.nanoseconds(ticks: .max, numer: 125, denom: 3) == .max)
    }

    @Test func foreignProcessWithoutCountersHasNoRates() {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond, fallbackCoreCount: 4)
        let counters = ProcessCounters(key: ProcessKey(pid: 88, startTime: 9), parentPID: 1, uid: 0, name: "WindowServer",
                                       cpuTimeNanoseconds: nil, diskBytesRead: nil, diskBytesWritten: nil,
                                       memoryBytes: nil, threadCount: nil)
        _ = accumulator.ingest(TaskManagerReadings(processes: .success([counters])), elapsed: nil)
        let frame = accumulator.ingest(TaskManagerReadings(processes: .success([counters])), elapsed: .seconds(1))
        let measurement = frame.snapshot.processes[0]
        #expect(measurement.cpuLoad == nil)
        #expect(measurement.diskReadPerSecond == nil)
        #expect(measurement.memoryBytes == nil)
        #expect(measurement.executablePath == nil)
    }

    /// Echtes System, nur lesend: der eigene Prozess mit plausiblen Zählern, fremde ohne Pfad und Zähler.
    @Test func readsOwnProcessFromSystem() throws {
        let counters = try ProcessUsageSampler().read()
        let own = try #require(counters.first { $0.key.pid == getpid() })
        #expect(own.uid == getuid())
        #expect((own.cpuTimeNanoseconds ?? 0) > 0)
        #expect((own.memoryBytes ?? 0) > 0)
        #expect((own.threadCount ?? 0) >= 1)
        #expect(own.executablePath?.isEmpty == false)
        #expect(!own.name.isEmpty)
        #expect(counters.contains { $0.key.pid == 1 && $0.uid == 0 })
        #expect(counters.filter { $0.uid != getuid() }.allSatisfy { $0.executablePath == nil && $0.cpuTimeNanoseconds == nil })
    }

    /// Wachbuch-Takt (TM-12.3): nur eigene Prozesse, je Prozess CPU-Zeit und Speicher – ohne Threads, Datenträger und
    /// Energie, die das Wachbuch nicht führt; im Hintergrund kostet jeder weitere Syscall je Prozess messbar (#530).
    @Test func ownLoadReadsOnlyOwnProcessesWithCPUAndMemory() throws {
        let counters = try ProcessUsageSampler.ownLoad().read()
        let own = try #require(counters.first { $0.key.pid == getpid() })
        #expect((own.cpuTimeNanoseconds ?? 0) > 0)
        #expect((own.memoryBytes ?? 0) > 0)
        #expect(own.threadCount == nil)
        #expect(own.diskBytesRead == nil && own.diskBytesWritten == nil && own.energyNanojoules == nil)
        #expect(own.executablePath?.isEmpty == false)
        #expect(counters.allSatisfy { $0.uid == getuid() })
        #expect(!counters.contains { $0.key.pid == 1 })
    }

    @Test func ownLoadIsTheWatchbookProcessSource() {
        #expect(TaskManagerSources.watchbook.processes is ProcessUsageSampler)
        #expect(TaskManagerSources.watchbook.configured == TaskManagerSources.system.configured)
    }

    /// Echtes System, nur lesend: Nach dem ersten Lesen genügt der gemerkte Umfang plus Reserve (ein Aufruf statt
    /// Größenabfrage und Lesen); das Ergebnis bleibt vollständig. Die Auswahl nach Benutzer liefert nur eigene.
    @Test func kernelListingStaysCompleteWithRememberedSize() throws {
        let first = try LibprocProcessTable.kernelProcesses()
        let second = try LibprocProcessTable.kernelProcesses()
        #expect(first.contains { $0.pid == getpid() } && second.contains { $0.pid == getpid() })
        #expect(second.contains { $0.pid == 1 })
        #expect(abs(first.count - second.count) < 64)
        let own = try LibprocProcessTable.kernelProcesses(ownedBy: getuid())
        #expect(own.contains { $0.pid == getpid() })
        #expect(own.allSatisfy { $0.uid == getuid() })
        #expect(abs(own.count - second.filter { $0.uid == getuid() }.count) < 64)
    }
}
