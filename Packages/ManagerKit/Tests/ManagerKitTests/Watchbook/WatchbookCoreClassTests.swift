import Foundation
import Testing
@testable import ManagerKit

/// Mittlere Last je Kernklasse im Wachbuch (#593, Folge zu #589): Die Klasse jedes Kerns kommt aus der gemeinsamen Quelle
/// `CoreKind` (Name der Leistungsstufe); Super-Kerne haben einen eigenen Wert und fließen in keinen anderen ein.
@Suite struct WatchbookCoreClassTests {
    private static let time = WatchbookFixtures.dayStart.addingTimeInterval(3_600)
    private let day = WatchbookFixtures.day

    /// Last je Kern: Super-Kerne 0,9, Leistungskerne 0,5, Effizienzkerne 0,1, Kerne ohne Klasse 0,7.
    private static func load(of kind: CoreKind) -> Double {
        switch kind {
        case .super: 0.9
        case .performance: 0.5
        case .efficiency: 0.1
        case .other, .unknown: 0.7
        }
    }

    private static func values(_ profile: ChipProfile, coreCount: Int) -> WatchbookValues {
        var snapshot = TaskManagerSnapshot()
        let kinds = profile.coreKinds(coreCount: coreCount)
        snapshot.cpu = CPULoad(total: 0.5, cores: kinds.map { CoreLoad(kind: $0, load: load(of: $0)) })
        return WatchbookPoint(time: time, snapshot: snapshot, currentUID: 501, thermalState: nil, power: nil).values
    }

    /// Klassischer Chip (Leistung und Effizienz): unverändert, ohne Wert für Super-Kerne.
    @Test func classicChipKeepsPerformanceAndEfficiency() {
        let values = Self.values(CoreKindTests.classic, coreCount: 16)
        #expect(values[.cpuPerformance] == 0.5)
        #expect(values[.cpuEfficiency] == 0.1)
        #expect(values[.cpuSuper] == nil)
    }

    /// Super und Leistung (M5 Max): Super-Kerne eigener Wert, die Leistungskerne bleiben Leistungskerne.
    @Test func superAndPerformanceChipRecordsBothClasses() {
        let values = Self.values(CoreKindTests.superAndPerformance, coreCount: 18)
        #expect(values[.cpuSuper] == 0.9)
        #expect(values[.cpuPerformance] == 0.5)
        #expect(values[.cpuEfficiency] == nil)
    }

    @Test func threeClassesAreRecordedSeparately() {
        let values = Self.values(CoreKindTests.threeClasses, coreCount: 14)
        #expect(values[.cpuSuper] == 0.9)
        #expect(values[.cpuPerformance] == 0.5)
        #expect(values[.cpuEfficiency] == 0.1)
    }

    /// Unbekannte Klassen künftiger Chips und Kerne ohne Klasse fließen in keinen Klassenwert ein.
    @Test func unknownClassesAreNotMixedIn() {
        let profile = CoreKindTests.profile([("Turbo", "T", 2), ("Performance", "P", 4), ("Efficiency", "E", 2)])
        let values = Self.values(profile, coreCount: 9)
        #expect(values[.cpuSuper] == nil)
        #expect(values[.cpuPerformance] == 0.5)
        #expect(values[.cpuEfficiency] == 0.1)
    }

    // MARK: Datei

    @Test func superCoresRoundTripThroughTheFile() {
        var point = WatchbookFixtures.point(at: WatchbookFixtures.dayStart.addingTimeInterval(100), consumers: false)
        point.values[.cpuSuper] = 0.875
        let read = WatchbookFileFormat.decode(
            WatchbookFileFormat.encode(points: [point], minutes: [], events: [], of: day), of: day)
        #expect(read.brokenLineCount == 0)
        #expect(read.points.first?.values[.cpuSuper] == 0.875)
    }

    /// Zeilen aus der Zeit vor #593 (ohne Spalte für Super-Kerne) bleiben lesbar; dort ist sie nicht gemessen.
    @Test func rowsWithoutSuperCoresStayReadable() throws {
        let older = WatchbookMetric.allCases.filter { $0.rawValue < WatchbookMetric.cpuSuper.rawValue }
        let written: [WatchbookMetric: String] = [.cpuPerformance: "625", .neuralEnginePower: "3"]
        let values = older.map { (metric: WatchbookMetric) -> String in written[metric] ?? "" }.joined(separator: ",")
        let text = "W\t1\nP\t100\t\(values)\t\t\nM\t60\t6\t\(values)\t\(values)\t\t\n"
        let contents = WatchbookFileFormat.decode(Array(text.utf8), of: day)
        #expect(contents.brokenLineCount == 0)
        let point = try #require(contents.points.first)
        #expect(point.values[.cpuPerformance] == 0.625)
        #expect(point.values[.neuralEnginePower] == 0.03)
        #expect(point.values[.cpuSuper] == nil)
        #expect(contents.minutes.first?.maximum[.cpuPerformance] == 0.625)
    }
}
