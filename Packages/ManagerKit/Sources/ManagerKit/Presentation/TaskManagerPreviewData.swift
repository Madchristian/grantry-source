#if DEBUG
import Foundation

/// Fester Stand des Task-Managers für SwiftUI-Previews und Sichtprüfungen – ohne echte Messung. 180 erfundene Takte
/// laufen durch den echten `TaskManagerAccumulator`, damit Raten und Verlauf wie im Betrieb entstehen.
public enum TaskManagerPreviewData {
    public static let configured: Set<TaskManagerSource> = [.cpu, .memory, .disks, .interfaces, .gpu]
    /// 3 Tage, 4 Stunden, 17 Minuten, 22 Sekunden.
    public static let uptime: TimeInterval = 3 * 86_400 + 4 * 3_600 + 17 * 60 + 22
    public static let frame = makeFrame(ticks: 180)

    /// 4 Effizienz- und 12 Leistungskerne wie der Entwickler-Mac.
    static let coreKinds: [CoreKind] = Array(repeating: .efficiency, count: 4)
        + Array(repeating: .performance, count: 12)
    static let physicalBytes: UInt64 = 48 << 30

    static func makeFrame(ticks: Int) -> TaskManagerFrame {
        frames(count: 1, after: ticks - 1, processes: false)[0]
    }

    /// Fake-Quelle des Render-Wächters (#372): `count` aufeinanderfolgende Messtakte, der erste gleich `frame`. Mit
    /// `processes` auch eine Handvoll Prozesse, deren Rangfolge nach CPU fast jeden Takt wechselt.
    public static func frames(count: Int, after warmup: Int = 179, processes: Bool = false,
                              coreKinds: [CoreKind]? = nil) -> [TaskManagerFrame] {
        let coreKinds = coreKinds ?? Self.coreKinds
        var accumulator = TaskManagerAccumulator(interval: .oneSecond, fallbackCoreCount: coreKinds.count)
        var counters = Counters(processes: processes, coreKinds: coreKinds)
        var frames: [TaskManagerFrame] = []
        for tick in 0..<(warmup + count) {
            var frame = accumulator.ingest(counters.advance(to: Double(tick)), elapsed: tick == 0 ? nil : .seconds(1))
            // Wie `TaskManagerModel`: Jeder Takt trägt den thermischen Zustand der Quelle.
            frame.snapshot.thermal = .nominal
            if tick >= warmup { frames.append(frame) }
        }
        return frames
    }

    /// Prozesse der Fake-Quelle: Name, Benutzer (501, root oder ein Dienstkonto), Grundlast und Phase der Lastwelle.
    private static let processes: [(name: String, uid: UInt32, load: Double, phase: Double)] = [
        ("Safari", 501, 0.08, 0), ("Xcode", 501, 0.12, 1.1), ("WindowServer", 88, 0.06, 2.3),
        ("kernel_task", 0, 0.05, 3.7), ("mds_stores", 0, 0.03, 0.6), ("Mail", 501, 0.02, 4.2),
        ("Music", 501, 0.025, 5.1), ("swift-frontend", 501, 0.1, 1.9), ("launchd", 0, 0.01, 2.8),
        ("Finder", 501, 0.015, 3.3),
    ]

    /// Kumulative Zähler, die je Takt um Wellen mit gelegentlichen Lastspitzen wachsen.
    private struct Counters {
        let processes: Bool
        let coreKinds: [CoreKind]
        var processTime = [UInt64](repeating: 0, count: TaskManagerPreviewData.processes.count)
        var busy: [UInt64]
        var idle: [UInt64]
        var system: [UInt64]
        var diskRead: UInt64 = 0
        var diskWritten: UInt64 = 0
        var diskOperations: UInt64 = 0
        var diskBusy: UInt64 = 0
        var received: UInt64 = 0
        var sent: UInt64 = 0

        init(processes: Bool, coreKinds: [CoreKind]) {
            self.processes = processes
            self.coreKinds = coreKinds
            busy = Array(repeating: 0, count: coreKinds.count)
            idle = busy
            system = busy
        }

        mutating func advance(to t: Double) -> TaskManagerReadings {
            let burst = sin(t / 23) > 0.8 ? 0.4 : 0
            for (index, kind) in coreKinds.enumerated() {
                let base = kind == .performance ? 0.3 : 0.15
                let wave = 0.2 * sin(t / 7 + Double(index)) + 0.08 * sin(t / 2.3 + Double(index) * 0.7)
                let load = min(max(base + wave + burst * (kind == .performance ? 1 : 0.5), 0), 1)
                busy[index] += UInt64(load * 1_000)
                idle[index] += UInt64((1 - load) * 1_000)
                // Rund ein Drittel der Last im System, wie unter macOS üblich.
                system[index] += UInt64(load * (0.3 + 0.1 * sin(t / 11)) * 1_000)
            }
            let read = 40e6 * pow(max(0, sin(t / 9)), 6) + 2e6
            let written = 18e6 * pow(max(0, sin(t / 13 + 1)), 4) + 4e5
            diskRead += UInt64(read)
            diskWritten += UInt64(written)
            diskOperations += UInt64((read + written) / 65_536)
            diskBusy += UInt64(min((read + written) / 60e6, 1) * 1e9)
            received += UInt64(6e6 + 5e6 * sin(t / 5))
            sent += UInt64(1.2e6 + 1e6 * sin(t / 8))
            let gib = Double(1 << 30)
            let components = MemoryComponents(appBytes: UInt64((14 + 2 * sin(t / 40)) * gib),
                                              wiredBytes: UInt64(3.4 * gib),
                                              compressedBytes: UInt64((2.2 + 0.6 * sin(t / 60)) * gib),
                                              cachedBytes: UInt64(9 * gib))
            return TaskManagerReadings(
                processes: processes ? .success(advanceProcesses(to: t)) : nil,
                cpu: .success(CPULoadReading(cores: coreKinds.indices.map {
                    CoreTicks(kind: coreKinds[$0], busy: busy[$0], idle: idle[$0], system: system[$0])
                })),
                memory: .success(MemoryStatus(physicalBytes: physicalBytes, usedBytes: components.usedBytes,
                                              swapUsedBytes: UInt64(1.2 * gib), swapTotalBytes: 2 << 30,
                                              pressure: .normal, processCount: 642, components: components)),
                disks: .success([DriveCounters(id: "disk0", name: "APPLE SSD AP1024Z", bytesRead: diskRead,
                                               bytesWritten: diskWritten, operations: diskOperations,
                                               busyNanoseconds: diskBusy)]),
                interfaces: .success([
                    InterfaceCounters(name: "lo0", bytesReceived: 0, bytesSent: 0, addresses: ["127.0.0.1", "::1"]),
                    InterfaceCounters(name: "en0", bytesReceived: received, bytesSent: sent, displayName: "WLAN",
                                      addresses: ["192.168.178.24", "fe80::1c2b:4aff:fe10:7d3e%en0"]),
                    InterfaceCounters(name: "utun3", bytesReceived: 0, bytesSent: 0,
                                      addresses: ["fe80::ce81:b1c:bd2c:69e%utun3"]),
                ]),
                gpu: .success(GPULoadReading(utilization: min(0.18 + 0.5 * pow(max(0, sin(t / 17)), 3), 1),
                                             usedMemoryBytes: UInt64(2.8 * gib)))
            )
        }

        /// CPU-Zeit wächst je Prozess um eine eigene Welle (Nanosekunden je Takt über alle Kerne).
        mutating func advanceProcesses(to t: Double) -> [ProcessCounters] {
            TaskManagerPreviewData.processes.enumerated().map { index, process in
                let load = max(process.load * (1 + 0.9 * sin(t / 1.7 + process.phase)), 0)
                processTime[index] += UInt64(load * Double(coreKinds.count) * 1e9)
                let pid = Int32(100 + index * 37)
                return ProcessCounters(key: ProcessKey(pid: pid, startTime: UInt64(1_000 + index)), parentPID: 1,
                                       uid: process.uid, name: process.name, cpuTimeNanoseconds: processTime[index],
                                       diskBytesRead: UInt64(t * 4e5 * Double(index + 1)),
                                       diskBytesWritten: UInt64(t * 1e5 * Double(index + 1)),
                                       memoryBytes: UInt64(200 + 150 * index) << 20, threadCount: 4 + index,
                                       energyNanojoules: processTime[index] * 3)
            }
        }
    }
}

extension TaskManagerPreviewData {
    /// Übersicht der Menüleiste (#495): Stand, Chip und Kontext eines Macs mit den Stufen `levels` (schnellste zuerst),
    /// mit Prozessen, Akku, Startvolume, fester Laufzeit und Durchschnittslast.
    public struct OverviewSample {
        public let frame: TaskManagerFrame
        public let profile: ChipProfile
        public let context: MenuBarOverviewContext
    }

    /// Eine Leistungsstufe der Vorschau: Name laut System (`hw.perflevelN.name`), Typ im Gerätebaum, Kernzahl.
    public struct SampleLevel {
        public let name: String?
        public let type: String
        public let count: Int

        public init(name: String?, type: String, count: Int) {
            self.name = name
            self.type = type
            self.count = count
        }
    }

    /// Cluster zu je höchstens sechs Kernen wie beim M4 Max.
    static let sampleClusterSize = 6

    /// Mac mit `performance` Leistungs- und `efficiency` Effizienzkernen.
    public static func overviewSample(performance: Int, efficiency: Int, name: String) -> OverviewSample {
        overviewSample(levels: [SampleLevel(name: "Performance", type: "P", count: performance),
                                SampleLevel(name: "Efficiency", type: "E", count: efficiency)], name: name)
    }

    /// Kernnummern wie auf Apple-Chips von der langsamsten Stufe an; die Kernarten liest der Stand aus dem Profil wie
    /// `CPULoadSampler` im Betrieb.
    public static func overviewSample(levels: [SampleLevel], name: String) -> OverviewSample {
        var cpus: [ChipFacts.CPU] = []
        var clusterID = 0
        for level in levels.reversed() {
            let size = min(level.count, sampleClusterSize)
            for core in 0..<level.count {
                cpus.append(ChipFacts.CPU(logicalID: cpus.count, clusterID: clusterID + core / max(size, 1),
                                          clusterType: level.type))
            }
            clusterID += size > 0 ? (level.count + size - 1) / size : 0
        }
        let facts = ChipFacts(brand: name, memoryBytes: physicalBytes,
                              levels: levels.map { ChipFacts.Level(name: $0.name, logicalCPUs: $0.count) }, cpus: cpus)
        let profile = ChipProfile(facts: facts)
        var frame = frames(count: 1, processes: true, coreKinds: profile.coreKinds(coreCount: cpus.count))[0]
        frame.snapshot.battery = BatteryReading(charge: 0.82, source: .externalPower, isCharging: true)
        let apps = [RunningApp(pid: 100, bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app",
                               name: "Safari"),
                    RunningApp(pid: 137, bundleID: "com.apple.dt.Xcode", bundlePath: "/Applications/Xcode.app",
                               name: "Xcode")]
        let context = MenuBarOverviewContext(
            startupVolume: VolumeUsage(totalBytes: 994_662_584_320, availableBytes: 412_884_131_840), apps: apps,
            currentUID: 501, loadAverage: LoadAverage(one: 3.42, five: 2.87, fifteen: 2.51), uptime: uptime
        )
        return OverviewSample(frame: frame, profile: profile, context: context)
    }
}
#endif
