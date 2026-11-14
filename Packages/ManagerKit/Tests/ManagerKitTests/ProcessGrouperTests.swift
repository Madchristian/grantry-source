import Testing
@testable import ManagerKit

@Suite struct ProcessGrouperTests {
    private static let me: UInt32 = 501
    private static let browser = RunningApp(pid: 100, bundleID: "com.example.browser",
                                            bundlePath: "/Applications/Browser.app", name: "Browser")

    private func process(_ pid: Int32, parent: Int32 = 1, uid: UInt32 = me, path: String? = nil, name: String? = nil,
                         cpu: Double? = nil, memory: UInt64? = nil) -> ProcessMeasurement {
        ProcessMeasurement(key: ProcessKey(pid: pid, startTime: 1), parentPID: parent, uid: uid, name: name ?? "p\(pid)",
                           cpuLoad: cpu, memoryBytes: memory, diskReadPerSecond: nil, diskWritePerSecond: nil,
                           threadCount: nil, executablePath: uid == Self.me ? path : nil)
    }

    private func group(_ processes: [ProcessMeasurement], apps: [RunningApp] = [browser],
                       network: [ProcessKey: Double]? = nil) -> [ProcessGroup] {
        ProcessGrouper.group(processes, apps: apps, currentUID: Self.me, network: network)
    }

    @Test func helpersAndDescendantsBelongToTheirApp() throws {
        let groups = group([
            process(103, parent: 102),
            process(102, parent: 100, path: "/usr/bin/tool"),
            process(101, path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            process(100, path: "/Applications/Browser.app/Contents/MacOS/Browser"),
        ])
        let apps = try #require(groups.first { $0.kind == .apps })
        #expect(apps.entries.count == 1)
        #expect(apps.entries[0].app == Self.browser)
        #expect(apps.entries[0].processes.map(\.key.pid) == [100, 101, 102, 103])
        #expect(groups.map(\.kind) == [.apps])
    }

    @Test func ownProcessWithoutAppIsBackground() {
        let groups = group([process(200, path: "/usr/local/bin/agent")])
        #expect(groups.map(\.kind) == [.background])
        #expect(groups[0].entries[0].app == nil)
        #expect(groups[0].entries[0].name == "p200")
    }

    @Test func foreignProcessIsSystemEvenWhenStartedByApp() {
        let groups = group([process(100, path: "/Applications/Browser.app/Contents/MacOS/Browser"),
                            process(300, parent: 100, uid: 0)])
        #expect(groups.map(\.kind) == [.apps, .system])
        #expect(groups[1].entries[0].processes[0].key.pid == 300)
    }

    @Test func innermostBundleWins() {
        let simulator = RunningApp(pid: 400, bundleID: nil,
                                   bundlePath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app",
                                   name: "Simulator")
        let xcode = RunningApp(pid: 410, bundleID: nil, bundlePath: "/Applications/Xcode.app", name: "Xcode")
        let helper = process(401, path: simulator.bundlePath! + "/Contents/MacOS/SimulatorHelper")
        let groups = group([helper, process(400), process(410)], apps: [xcode, simulator])
        let owner = groups[0].entries.first { $0.processes.contains(helper) }?.app
        #expect(owner == simulator)
    }

    @Test func appWithoutMeasuredProcessIsOmitted() {
        #expect(group([process(200)]).map(\.kind) == [.background])
    }

    @Test func entriesAreSortedByName() {
        let groups = group([process(3, name: "zsh"), process(4, name: "Agent"), process(5, name: "bash")], apps: [])
        #expect(groups[0].entries.map(\.name) == ["Agent", "bash", "zsh"])
    }

    @Test func totalsSumMeasuredValuesOnly() {
        let groups = group([process(100, path: "/Applications/Browser.app/Contents/MacOS/Browser", cpu: 0.25, memory: 10),
                            process(101, parent: 100, cpu: 0.5),
                            process(300, uid: 0)])
        #expect(groups[0].totals.cpuLoad == 0.75)
        #expect(groups[0].totals.memoryBytes == 10)
        #expect(groups[0].entries[0].figures.map(\.cpuLoad) == [0.25, 0.5])
        #expect(groups[1].totals.cpuLoad == nil)
        #expect(groups[1].totals.memoryBytes == nil)
    }

    @Test func networkCountsMissingProcessesAsIdleWhileMeasuring() {
        let measuring = group([process(1_000), process(1_001)], apps: [],
                              network: [ProcessKey(pid: 1_000, startTime: 1): 2_000])
        #expect(measuring[0].entries.map(\.totals.networkPerSecond) == [2_000, 0])
        #expect(measuring[0].totals.networkPerSecond == 2_000)
        #expect(group([process(1_000)], apps: [])[0].totals.networkPerSecond == nil)
    }

    @Test func loopInParentChainEnds() {
        let groups = group([process(5, parent: 6), process(6, parent: 5)], apps: [])
        #expect(groups.map(\.kind) == [.background])
        #expect(groups[0].processCount == 2)
    }

    /// Für den App-Verlauf je Takt (#489): dieselben Einträge wie die Gruppen „Apps“ und „Hintergrund“, ohne „System“
    /// und ohne Sortierung.
    @Test func ownEntriesAreTheAppAndBackgroundEntriesWithoutSystem() {
        let processes = [
            process(100, path: "/Applications/Browser.app/Contents/MacOS/Browser", cpu: 0.2),
            process(101, parent: 100, path: "/usr/bin/tool", cpu: 0.1),
            process(200, path: "/usr/local/bin/zeta", cpu: 0.3),
            process(201, path: "/usr/local/bin/alpha"),
            process(300, parent: 100, uid: 0, cpu: 0.5),
        ]
        let network = [ProcessKey(pid: 200, startTime: 1): 1_000.0]
        let own = ProcessGrouper.ownEntries(processes, apps: [Self.browser], currentUID: Self.me, network: network)
        let grouped = group(processes, network: network).filter { $0.kind != .system }.flatMap(\.entries)
        #expect(Set(own) == Set(grouped))
        #expect(own.count == grouped.count)
        #expect(!own.contains { $0.processes.contains { $0.uid != Self.me } })
    }

    /// Auswahl wie bisher in der Übersicht der Menüleiste: alle Gruppen bilden, dann die Einträge mit der höchsten Last
    /// einsortieren. Vergleichsmaßstab für `entriesWithHighestCPULoad` (#626).
    private func highestFromGroups(_ processes: [ProcessMeasurement], apps: [RunningApp], count: Int)
        -> [RankedProcessEntry] {
        var top: [RankedProcessEntry] = []
        for group in ProcessGrouper.group(processes, apps: apps, currentUID: Self.me) {
            for entry in group.entries {
                guard let share = entry.totals.cpuLoad else { continue }
                let rank = top.firstIndex {
                    share > $0.cpuLoad || (share == $0.cpuLoad && entry.name < $0.entry.name)
                } ?? top.count
                guard rank < count else { continue }
                top.insert(RankedProcessEntry(entry: entry, kind: group.kind, cpuLoad: share), at: rank)
                if top.count > count { top.removeLast() }
            }
        }
        return top
    }

    @Test func highestCPULoadSumsAppsAndKeepsGroupOfEachEntry() {
        let processes = [
            process(100, path: "/Applications/Browser.app/Contents/MacOS/Browser", cpu: 0.02, memory: 100),
            process(101, parent: 100, path: "/usr/bin/tool", cpu: 0.03, memory: 50),
            process(200, path: "/usr/local/bin/zeta", cpu: 0.04),
            process(201, path: "/usr/local/bin/alpha"),
            process(300, uid: 0, name: "kernel_task", cpu: 0.01),
        ]
        let top = ProcessGrouper.entriesWithHighestCPULoad(processes, apps: [Self.browser], currentUID: Self.me, count: 2)
        #expect(top.map(\.entry.name) == ["Browser", "p200"])
        #expect(top.map(\.kind) == [.apps, .background])
        #expect(top.map(\.cpuLoad) == [0.02 + 0.03, 0.04])
        #expect(top[0].entry.processes.map(\.key.pid) == [100, 101])
        #expect(top[0].entry.totals.memoryBytes == 150)
        #expect(ProcessGrouper.entriesWithHighestCPULoad(processes, apps: [Self.browser], currentUID: Self.me, count: 9)
            .map(\.entry.name) == ["Browser", "p200", "kernel_task"])
        #expect(ProcessGrouper.entriesWithHighestCPULoad(processes, apps: [Self.browser], currentUID: Self.me, count: 0)
            .isEmpty)
    }

    /// Gleiche Einträge in gleicher Reihenfolge wie über die Gruppen, auch bei Gleichständen in Last und Namen, Apps
    /// ohne Messung und Prozessen ohne Last.
    @Test func highestCPULoadMatchesSelectionFromGroups() {
        let apps = (0..<6).map { index in
            RunningApp(pid: Int32(1_000 + index), bundleID: "com.example.app\(index)",
                       bundlePath: "/Applications/App\(index).app", name: index < 2 ? "Zwilling" : "App \(index)")
        }
        var seed: UInt64 = 626
        let next = { () -> Int in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        var processes = apps.map { app in
            process(app.pid, path: "\(app.bundlePath ?? "")/Contents/MacOS/App", cpu: next() % 3 == 0 ? nil : 0.01)
        }
        for pid in Int32(2_000)..<2_400 {
            // Wenige verschiedene Lasten und Namen: viele Gleichstände.
            let load = [nil, 0, 0.01, 0.02, 0.05, 0.1, Double(next() % 1_000) / 10_000][next() % 7]
            let owner = next() % 4
            processes.append(process(pid, parent: owner == 0 ? apps[next() % apps.count].pid : 1,
                                     uid: owner == 1 ? 0 : Self.me,
                                     path: owner == 2 ? "/Applications/App\(next() % apps.count).app/Contents/Helper" : nil,
                                     name: "tool\(next() % 5)", cpu: load, memory: UInt64(next() % 1_000)))
        }
        for count in [1, 3, 5, 40, 1_000] {
            let top = ProcessGrouper.entriesWithHighestCPULoad(processes, apps: apps, currentUID: Self.me, count: count)
            #expect(top == highestFromGroups(processes, apps: apps, count: count), "count \(count)")
        }
    }
}
