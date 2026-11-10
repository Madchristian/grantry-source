import Foundation
import TestSupport
@testable import ManagerKit

/// Feste Zeiten und Daten für die Wachbuch-Tests; keine Wanduhr (#214).
enum WatchbookFixtures {
    /// 7. November 2026, 00:00 UTC (Tag 20 764 seit 1970).
    static let dayStart = Date(timeIntervalSince1970: 1_794_009_600)
    static let day = WatchbookDay(containing: dayStart)
    static let currentUID: UInt32 = 501

    /// Ein Punkt mit Werten auf dem Raster der Datei (bleiben beim Lesen exakt gleich).
    static func point(at time: Date, cpu: Double? = 0.25, memory: Double? = 8_589_934_592,
                      received: Double? = 12_300, consumers: Bool = true) -> WatchbookPoint {
        var values = WatchbookValues()
        values[.cpuTotal] = cpu
        values[.cpuPerformance] = cpu
        values[.cpuEfficiency] = cpu.map { $0 / 2 }
        values[.memoryUsed] = memory
        values[.memoryCompressed] = 1_048_576
        values[.swapUsed] = 0
        values[.memoryPressure] = 0
        values[.diskRead] = 100
        values[.diskWrite] = 4_000
        values[.networkReceived] = received
        values[.networkSent] = 1_000
        values[.gpu] = 0.05
        values[.thermalState] = 0
        values[.batteryCharge] = 0.8
        values[.externalPower] = 1
        values[.power] = 4.5
        return WatchbookPoint(
            time: time, values: values,
            cpuConsumers: consumers ? [
                WatchbookConsumer(subject: .program("Xcode"), value: 0.12),
                WatchbookConsumer(subject: .systemProcess("WindowServer"), value: 0.03),
                WatchbookConsumer(subject: .otherAccounts, value: 0.01),
            ] : [],
            memoryConsumers: consumers ? [
                WatchbookConsumer(subject: .program("Xcode"), value: 2_147_483_648),
                WatchbookConsumer(subject: .systemProcess("kernel_task"), value: 1_073_741_824),
            ] : []
        )
    }

    /// Punkte im 10-s-Takt ab `start`.
    static func points(from start: Date, count: Int, every interval: TimeInterval = 10,
                       cpu: (Int) -> Double? = { _ in 0.25 }) -> [WatchbookPoint] {
        (0..<count).map { point(at: start.addingTimeInterval(Double($0) * interval), cpu: cpu($0)) }
    }

    static func event(_ kind: WatchbookEvent.Kind = .finding, start: Date, end: Date?,
                      id: UUID = UUID(), summary: String = "CPU über 80 % seit 2 Minuten") -> WatchbookEvent {
        WatchbookEvent(id: id, kind: kind, type: "sustainedLoad", start: start, end: end,
                       tone: kind == .finding ? .finding : nil, subject: .program("Xcode"), summary: summary)
    }

    /// Symlinkfreier Ordner (`PrivateDirectory` öffnet ohne Symlink-Auflösung).
    static func withStore<T>(sizeLimit: Int = WatchbookStore.defaultSizeLimit,
                             _ body: (WatchbookStore) throws -> T) throws -> T {
        try ScratchDirectory.withCanonical(prefix: "watchbook") { scratch in
            try body(WatchbookStore(directory: scratch.appending(path: "Grantry/Watchbook"), sizeLimit: sizeLimit))
        }
    }

    static func names(in store: WatchbookStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
    }

    static func url(of day: WatchbookDay, in store: WatchbookStore) -> URL {
        store.directory.appending(path: day.fileName)
    }

    static func size(of url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
    }
}
