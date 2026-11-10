#if DEBUG
import Foundation

/// Fester Stand des Energie-Tabs für SwiftUI-Previews und Sichtprüfungen – ohne Systemzugriff. 300 erfundene Takte
/// laufen durch den echten `TaskManagerAccumulator`, damit Leistung, Trend und Verlauf wie im Betrieb entstehen.
/// Prozesse und Apps wie `ProcessListPreviewData`; fremde Prozesse ohne Zähler wie auf einem Mac ohne Root.
public enum EnergyPreviewData {
    public static let frame = makeFrame(ticks: 300, power: .battery)
    /// Mac ohne Akku (etwa Mac mini): nur Prozess-Energie.
    public static let frameWithoutBattery = makeFrame(ticks: 300, power: nil)
    /// Akku lädt an einem 100-W-Netzteil.
    public static let frameCharging = makeFrame(ticks: 300, power: .externalPower)

    public static func presentation(for frame: TaskManagerFrame,
                                    options: ProcessListOptions = EnergyPresentation.defaultOptions)
        -> ProcessListPresentation {
        ProcessListPresenter.present(frame.snapshot, apps: ProcessListPreviewData.apps,
                                     currentUID: ProcessListPreviewData.currentUID, network: nil, options: options,
                                     physicalMemory: ProcessListPreviewData.physicalMemory)
    }

    private struct Process: Sendable {
        let pid: Int32
        let name: String
        var parent: Int32 = 1
        /// Grundleistung in Milliwatt; `nil` = Prozess eines anderen Benutzers ohne Zähler.
        let milliwatts: Double?
        var uid = ProcessListPreviewData.currentUID
        var path: String?
    }

    private static let processes = [
        Process(pid: 610, name: "Safari", milliwatts: 320, path: "/Applications/Safari.app/Contents/MacOS/Safari"),
        Process(pid: 612, name: "Safari Web Content", parent: 610, milliwatts: 1_350),
        Process(pid: 613, name: "Safari Graphics and Media", parent: 610, milliwatts: 260),
        Process(pid: 720, name: "Xcode", milliwatts: 900, path: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
        Process(pid: 721, name: "SourceKitService", parent: 720, milliwatts: 2_600),
        Process(pid: 722, name: "XCBBuildService", parent: 720, milliwatts: 1_700),
        Process(pid: 830, name: "Mail", milliwatts: 25, path: "/System/Applications/Mail.app/Contents/MacOS/Mail"),
        Process(pid: 840, name: "Musik", milliwatts: 380, path: "/System/Applications/Music.app/Contents/MacOS/Music"),
        Process(pid: 2_001, name: "claude", milliwatts: 3_200),
        Process(pid: 2_002, name: "codex", milliwatts: 700),
        Process(pid: 2_003, name: "Dropbox", milliwatts: 140),
        Process(pid: 2_004, name: "photoanalysisd", milliwatts: 5_200),
        Process(pid: 2_005, name: "zsh", milliwatts: 0),
        Process(pid: 88, name: "WindowServer", milliwatts: nil, uid: 88),
        Process(pid: 1, name: "launchd", parent: 0, milliwatts: nil, uid: 0),
        Process(pid: 412, name: "mds_stores", milliwatts: nil, uid: 0),
    ]

    /// - Parameter power: Stromquelle des Akkus; `nil` = Mac ohne Akku.
    static func makeFrame(ticks: Int, power: PowerSourceState?) -> TaskManagerFrame {
        var accumulator = TaskManagerAccumulator(interval: .oneSecond, fallbackCoreCount: 16)
        var cpu = [UInt64](repeating: 0, count: processes.count)
        var energy = [UInt64](repeating: 0, count: processes.count)
        var frame = TaskManagerFrame.empty(interval: .oneSecond)
        for tick in 0..<ticks {
            let t = Double(tick)
            var counters: [ProcessCounters] = []
            var total = 0.0
            for (index, process) in processes.enumerated() {
                let key = ProcessKey(pid: process.pid, startTime: 1)
                guard let base = process.milliwatts else {
                    counters.append(ProcessCounters(key: key, parentPID: process.parent, uid: process.uid,
                                                    name: process.name, cpuTimeNanoseconds: nil, diskBytesRead: nil,
                                                    diskBytesWritten: nil, memoryBytes: nil, threadCount: nil))
                    continue
                }
                let wave = 1 + 0.35 * sin(t / 9 + Double(index)) + (sin(t / 31 + Double(index)) > 0.9 ? 0.6 : 0)
                let milliwatts = base * max(wave, 0.1)
                total += milliwatts
                energy[index] += UInt64(milliwatts * 1_000_000)
                cpu[index] += UInt64(milliwatts / 2_700 * 1_000_000_000)
                counters.append(ProcessCounters(key: key, parentPID: process.parent, uid: process.uid,
                                                name: process.name, cpuTimeNanoseconds: cpu[index], diskBytesRead: 0,
                                                diskBytesWritten: 0, memoryBytes: 256 << 20, threadCount: 8,
                                                executablePath: process.path, energyNanojoules: energy[index]))
            }
            let system = total + 6_500 + 1_800 * sin(t / 11) + 2_500 * pow(max(0, sin(t / 23)), 4)
            let reading = power.map { battery(source: $0, tick: t, system: system) }
            frame = accumulator.ingest(TaskManagerReadings(processes: .success(counters), battery: reading.map {
                .success($0)
            }),
                                       elapsed: tick == 0 ? nil : .seconds(1))
        }
        return frame
    }

    /// Akkubetrieb mit 254 min Restzeit oder Laden mit gut 30 W an einem 100-W-Netzteil.
    private static func battery(source: PowerSourceState, tick t: Double, system: Double) -> BatteryReading {
        let charging = source == .externalPower
        return BatteryReading(charge: charging ? 0.46 + t / 30_000 : 0.82 - t / 30_000, source: source,
                              isCharging: charging, minutesToEmpty: charging ? nil : 254,
                              minutesToFull: charging ? 72 : nil, cycleCount: 86, designCycleCount: 1_000,
                              maximumCapacity: 0.976, condition: .normal,
                              batteryMilliwatts: charging ? 31_400 + 900 * sin(t / 13) : -system,
                              systemMilliwatts: system,
                              adapter: charging ? PowerAdapterReading(watts: 100, name: "pd charger") : nil)
    }
}
#endif
