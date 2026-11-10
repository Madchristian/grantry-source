import Testing
@testable import ManagerKit

@Suite struct PerformancePresentationTests {
    private typealias P = PerformancePresentation

    #if DEBUG
    @Test func previewFrameShowsAllTilesInFixedOrder() {
        let tiles = P.tiles(for: TaskManagerPreviewData.frame.snapshot, configured: TaskManagerPreviewData.configured)
        #expect(tiles.map(\.metric) == [.cpu, .memory, .drive("disk0"), .interface("en0"), .gpu])
    }
    #endif

    @Test func unconfiguredSourcesHaveNoTile() {
        #expect(P.tiles(for: TaskManagerSnapshot(), configured: []).isEmpty)
    }

    @Test func notYetMeasuredValuesShowDash() {
        let tiles = P.tiles(for: TaskManagerSnapshot(), configured: [.cpu, .memory])
        #expect(tiles.map(\.value) == ["–", "–"])
    }

    @Test func gpuTileNeedsUtilization() {
        var snapshot = TaskManagerSnapshot()
        snapshot.gpu = GPULoadReading(utilization: nil, usedMemoryBytes: 5)
        #expect(P.tiles(for: snapshot, configured: [.gpu]).isEmpty)
        snapshot.gpu = GPULoadReading(utilization: 0.42, usedMemoryBytes: 5)
        #expect(P.tiles(for: snapshot, configured: [.gpu]).map(\.value) == ["42 %"])
    }

    @Test func onlyRoutableInterfacesGetATile() {
        let interfaces = [
            InterfaceThroughput(name: "lo0", receivedPerSecond: 1, sentPerSecond: 1, addresses: ["127.0.0.1"]),
            InterfaceThroughput(name: "utun3", receivedPerSecond: 0, sentPerSecond: 0, addresses: ["fe80::1%utun3"]),
            InterfaceThroughput(name: "en7", receivedPerSecond: 0, sentPerSecond: 0, addresses: ["169.254.3.4"]),
            InterfaceThroughput(name: "en0", receivedPerSecond: 0, sentPerSecond: 0, displayName: "WLAN",
                                addresses: ["fe80::2%en0", "192.168.178.24"]),
        ]
        #expect(P.visibleInterfaces(interfaces).map(\.name) == ["en0"])
    }

    /// Bewertung 2026.11.7-1188, Mangel 4: Übersicht und Popover zeigen die Schnittstelle der Default-Route, ohne
    /// sie die mit dem meisten Verkehr; Loopback und Schnittstellen ohne Adresse nie.
    @Test func primaryInterfaceIsDefaultRouteThenBusiestVisibleOne() {
        let wlan = InterfaceThroughput(name: "en0", receivedPerSecond: 900, sentPerSecond: 100, displayName: "WLAN",
                                       addresses: ["192.168.178.24"])
        let lan = InterfaceThroughput(name: "en8", receivedPerSecond: 50, sentPerSecond: 10,
                                      addresses: ["192.168.178.30"])
        let loopback = InterfaceThroughput(name: "lo0", receivedPerSecond: 1e9, sentPerSecond: 1e9,
                                           addresses: ["127.0.0.1"])
        let routed = InterfaceThroughput(name: "en8", receivedPerSecond: 50, sentPerSecond: 10,
                                         addresses: ["192.168.178.30"], isPrimary: true)
        #expect(P.primaryInterface(in: [loopback, wlan, routed])?.name == "en8")
        #expect(P.primaryInterface(in: [loopback, lan, wlan])?.name == "en0")
        let unmeasured = [lan, wlan].map {
            InterfaceThroughput(name: $0.name, receivedPerSecond: nil, sentPerSecond: nil, addresses: $0.addresses)
        }
        #expect(P.primaryInterface(in: unmeasured)?.name == "en8")
        #expect(P.primaryInterface(in: [loopback]) == nil)
    }

    @Test func interfaceTileUsesDisplayName() {
        var snapshot = TaskManagerSnapshot()
        snapshot.interfaces = [InterfaceThroughput(name: "en0", receivedPerSecond: 1_234, sentPerSecond: nil,
                                                   displayName: "WLAN", addresses: ["192.0.2.1"])]
        let tile = P.tiles(for: snapshot, configured: [.interfaces]).first
        #expect(tile?.title == "WLAN")
        #expect(tile?.detail == "en0")
        #expect(tile?.value == "↓ 1,2 KB/s · ↑ –")
    }

    /// TM-11.4 (#373): Übersicht und Popover zeigen nur den Anzeigenamen; VoiceOver und die Gegenprobe der Default-Route
    /// (plausibility.py) brauchen den BSD-Namen. Andere Kacheln behalten ihren Titel, ihr Detail ist keine Bezeichnung.
    @Test func spokenTitleNamesTheInterfaceBehindTheDisplayName() {
        var snapshot = TaskManagerSnapshot()
        snapshot.interfaces = [
            InterfaceThroughput(name: "en8", receivedPerSecond: 1, sentPerSecond: 1, displayName: "Ethernet",
                                addresses: ["192.0.2.1"]),
            InterfaceThroughput(name: "en9", receivedPerSecond: 1, sentPerSecond: 1, addresses: ["192.0.2.2"]),
        ]
        snapshot.cpu = CPULoad(total: 0.2, cores: [CoreLoad(kind: .performance, load: 0.2)])
        let tiles = P.tiles(for: snapshot, configured: [.cpu, .interfaces])
        #expect(tiles.map(\.spokenTitle) == ["CPU", "Ethernet en8", "en9"])
    }

    /// TM-11.9 (#378, Bewertung 2026.11.7 Mangel 12): Jede Kachel ist für VoiceOver ein Element mit Titel, Detail und Wert;
    /// Raten ausgeschrieben statt „L/S“ und Pfeilen, Kacheln gleicher Art unterscheiden sich über Laufwerk und Schnittstelle.
    @Test func accessibilityLabelNamesTitleDetailAndSpokenValue() {
        var snapshot = TaskManagerSnapshot()
        snapshot.cpu = CPULoad(total: 0.2, cores: [CoreLoad(kind: .performance, load: 0.2)])
        snapshot.drives = [DriveThroughput(id: "disk3", name: "SSD", readPerSecond: 1_200, writePerSecond: nil),
                           DriveThroughput(id: "disk5", name: "SSD", readPerSecond: 0, writePerSecond: 0)]
        snapshot.interfaces = [
            InterfaceThroughput(name: "en0", receivedPerSecond: 1_234, sentPerSecond: 0, displayName: "WLAN",
                                addresses: ["192.0.2.1"]),
            InterfaceThroughput(name: "en9", receivedPerSecond: nil, sentPerSecond: nil, addresses: ["192.0.2.2"]),
        ]
        let labels = P.tiles(for: snapshot, configured: [.cpu, .disks, .interfaces]).map(\.accessibilityLabel)
        #expect(labels == ["CPU, 1 Kerne, 20 %",
                           "SSD, disk3, Lesen 1,2 KB/s, Schreiben –",
                           "SSD, disk5, Lesen 0 B/s, Schreiben 0 B/s",
                           "WLAN en0, Empfangen 1,2 KB/s, Senden 0 B/s",
                           "en9, Empfangen –, Senden –"])
        #expect(Set(labels).count == labels.count)
    }

    @Test func accessibilityLabelOfOtherTilesKeepsTheirValue() {
        let tile = PerformanceTile(metric: .gpu, title: "GPU", value: "30 %", detail: "")
        #expect(tile.accessibilityLabel == "GPU, 30 %")
    }

    #if DEBUG
    @Test func cpuStatsWithoutProcessSourceUseMemoryProcessCount() {
        let stats = P.stats(for: .cpu, in: TaskManagerPreviewData.frame.snapshot, uptime: TaskManagerPreviewData.uptime)
        #expect(stats.map(\.title) == ["Auslastung", "Kerne", "Prozesse", "Threads", "Laufzeit"])
        #expect(stats.dropFirst().map(\.value) == ["12 P · 4 E", "642", "–", "3:04:17:22"])
    }
    #endif

    @Test func threadsAreSummedFromProcesses() {
        var snapshot = TaskManagerSnapshot()
        snapshot.processes = [3, nil, 4].enumerated().map { index, threads in
            ProcessMeasurement(key: ProcessKey(pid: Int32(index + 1), startTime: 1), parentPID: 1, uid: 501, name: "p",
                               cpuLoad: nil, memoryBytes: nil, diskReadPerSecond: nil, diskWritePerSecond: nil,
                               threadCount: threads)
        }
        let stats = P.stats(for: .cpu, in: snapshot, uptime: 0)
        // Bewertung 2026.11.7-1188, Mangel 9: Ein Prozess ohne Thread-Zahl (anderer Benutzer) macht die Summe zur
        // Teilmenge.
        #expect(stats.map(\.value) == ["–", "–", "3", "mind. 7", "0:00:00:00"])
        snapshot.processes.remove(at: 1)
        #expect(P.stats(for: .cpu, in: snapshot, uptime: 0)[3].value == "7")
    }

    @Test func memoryStatsShowComponentsSwapAndPressure() {
        var snapshot = TaskManagerSnapshot()
        let components = MemoryComponents(appBytes: 1 << 30, wiredBytes: 1 << 29, compressedBytes: 1 << 28,
                                          cachedBytes: 1 << 31)
        snapshot.memory = MemoryStatus(physicalBytes: 1 << 33, usedBytes: components.usedBytes, swapUsedBytes: 0,
                                       swapTotalBytes: 0, pressure: .warning, processCount: 1, components: components)
        let text = ProcessCleanupPresentation.memoryText
        #expect(P.stats(for: .memory, in: snapshot, uptime: 0).map(\.value) == [
            "\(text(components.usedBytes)) von \(text(1 << 33))", text(1 << 28), text(1 << 29), text(1 << 31),
            "kein Swap", "erhöht",
        ])
    }

    @Test func driveStatsShowRatesActiveTimeAndOperations() {
        var snapshot = TaskManagerSnapshot()
        snapshot.drives = [DriveThroughput(id: "disk0", name: "SSD", readPerSecond: 3_400_000, writePerSecond: 0,
                                           operationsPerSecond: 1_234.4, activeShare: 0.071)]
        #expect(P.stats(for: .drive("disk0"), in: snapshot, uptime: 0).map(\.value)
            == ["3,4 MB/s", "0 B/s", "7 %", "1.234/s"])
    }

    @Test func vanishedDriveShowsDashes() {
        #expect(P.stats(for: .drive("disk9"), in: TaskManagerSnapshot(), uptime: 0).map(\.value)
            == ["–", "–", "–", "–"])
    }

    @Test func interfaceStatsListRoutableAddresses() {
        var snapshot = TaskManagerSnapshot()
        snapshot.interfaces = [InterfaceThroughput(name: "en0", receivedPerSecond: 0, sentPerSecond: 512,
                                                   addresses: ["fe80::2%en0", "192.0.2.1", "2001:db8::1"])]
        #expect(P.stats(for: .interface("en0"), in: snapshot, uptime: 0).map(\.value)
            == ["0 B/s", "512 B/s", "192.0.2.1, 2001:db8::1"])
    }

    @Test func uptimeCountsDaysHoursMinutesSeconds() {
        #expect(P.uptimeText(0) == "0:00:00:00")
        #expect(P.uptimeText(90_061.7) == "1:01:01:01")
    }

    #if DEBUG
    @Test func selectionFallsBackToFirstTile() {
        let tiles = P.tiles(for: TaskManagerPreviewData.frame.snapshot, configured: TaskManagerPreviewData.configured)
        #expect(P.resolvedSelection(.gpu, in: tiles) == .gpu)
        #expect(P.resolvedSelection(.drive("disk9"), in: tiles) == .cpu)
        #expect(P.resolvedSelection(nil, in: tiles) == .cpu)
        #expect(P.resolvedSelection(.cpu, in: []) == nil)
    }
    #endif

    @Test func coreClustersShowPerformanceCoresFirstInSystemOrder() {
        let cores = [CoreLoad(kind: .efficiency, load: 0.5), CoreLoad(kind: .efficiency, load: 1),
                     CoreLoad(kind: .performance, load: 0.25), CoreLoad(kind: .performance, load: nil),
                     CoreLoad(kind: .performance, load: 0.75)]
        let clusters = P.coreClusters(cores)
        #expect(clusters.map(\.kind) == [.performance, .efficiency])
        #expect(clusters.map(\.cores) == [[2, 3, 4], [0, 1]])
        #expect(clusters[0].load == 0.5)
        #expect(clusters[1].load == 0.75)
        #expect(clusters[0].detail == "3 Kerne · CPU 2–4")
    }

    @Test func coresWithoutKindsShareOneCluster() {
        let clusters = P.coreClusters([CoreLoad(kind: .unknown, load: nil), CoreLoad(kind: .unknown, load: nil)])
        #expect(clusters.map(\.kind) == [.unknown])
        #expect(clusters[0].load == nil)
        #expect(clusters[0].title == "Kerne")
    }

    @Test func clusterDetailOmitsRangeWithGaps() {
        #expect(CoreCluster(kind: .performance, cores: [0, 2], load: nil).detail == "2 Kerne")
        #expect(CoreCluster(kind: .efficiency, cores: [5], load: nil).detail == "1 Kern")
    }

    #if DEBUG
    @Test func previewHistoryIsFilledLikeARunningSession() {
        let frame = TaskManagerPreviewData.frame
        #expect(frame.snapshot.unavailable.isEmpty)
        #expect(frame.history.points(for: .cpuTotal, in: .oneMinute).count == 60)
        #expect(frame.history.points(for: .memory(.cached), in: .oneMinute).allSatisfy { $0 != nil })
        #expect(frame.history.points(for: .received("en0"), in: .fiveMinutes).count == 36)
    }
    #endif
}
