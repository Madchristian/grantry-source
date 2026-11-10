import Foundation
import Testing
@testable import ManagerKit

@Suite struct AppUsageHistoryTests {
    static let safari = AppUsageSubject(kind: .app, bundleID: "com.apple.Safari", name: "Safari",
                                        bundlePath: "/Applications/Safari.app")
    static let claude = AppUsageSubject(kind: .process, bundleID: nil, name: "claude", bundlePath: nil)
    /// 2026-11-06 10:00 UTC.
    static let tenOClock = Date(timeIntervalSince1970: 1_793_959_200)

    static func sample(at end: Date, seconds: Double = 1, network: Bool = true,
                       _ usage: [(AppUsageSubject, AppUsageTotals)]) -> AppUsageSample {
        AppUsageSample(end: end, seconds: seconds, measuresNetwork: network, usage: usage)
    }

    static func totals(cpu: Double = 0, energy: Double? = nil, network: Double? = nil,
                       disk: Double = 0) -> AppUsageTotals {
        AppUsageTotals(cpuSeconds: cpu, energyJoules: energy, networkBytes: network, diskBytes: disk)
    }

    @Test func samplesOfOneHourAddUp() {
        var history = AppUsageHistory()
        history.add(Self.sample(at: Self.tenOClock.addingTimeInterval(10), [(Self.safari, Self.totals(cpu: 2))]))
        history.add(Self.sample(at: Self.tenOClock.addingTimeInterval(11), network: false,
                                [(Self.safari, Self.totals(cpu: 3, energy: 4))]))
        #expect(history.hours.count == 1)
        #expect(history.hours[0].start == Self.tenOClock)
        #expect(history.hours[0].measuredSeconds == 2)
        #expect(history.hours[0].networkSeconds == 1)
        #expect(history.hours[0].usage[Self.safari.id] == Self.totals(cpu: 5, energy: 4))
        #expect(history.subjects[Self.safari.id] == Self.safari)
    }

    @Test func newHourStartsNewBucket() {
        var history = AppUsageHistory()
        history.add(Self.sample(at: Self.tenOClock.addingTimeInterval(3_599), [(Self.claude, Self.totals(cpu: 1))]))
        history.add(Self.sample(at: Self.tenOClock.addingTimeInterval(3_600), [(Self.claude, Self.totals(cpu: 1))]))
        #expect(history.hours.map(\.start) == [Self.tenOClock, Self.tenOClock.addingTimeInterval(3_600)])
    }

    @Test func lateSampleOfEarlierHourKeepsOrder() {
        var history = AppUsageHistory()
        history.add(Self.sample(at: Self.tenOClock.addingTimeInterval(7_200), [(Self.claude, Self.totals(cpu: 1))]))
        history.add(Self.sample(at: Self.tenOClock, [(Self.claude, Self.totals(cpu: 1))]))
        #expect(history.hours.map(\.start) == [Self.tenOClock, Self.tenOClock.addingTimeInterval(7_200)])
    }

    @Test func pruneDropsHoursOlderThanThirtyDays() {
        var history = AppUsageHistory()
        history.add(Self.sample(at: Self.tenOClock, [(Self.safari, Self.totals(cpu: 100))]))
        history.add(Self.sample(at: Self.tenOClock.addingTimeInterval(86_400), [(Self.claude, Self.totals(cpu: 100))]))
        history.prune(now: Self.tenOClock.addingTimeInterval(AppUsageHistory.retention + 1))
        #expect(history.hours.count == 1)
        #expect(history.subjects.keys.sorted() == [Self.claude.id])
    }

    @Test func pruneDropsNegligibleEntriesOfFinishedHoursOnly() {
        var history = AppUsageHistory()
        let tiny = Self.totals(cpu: 0.5, energy: 0.5, network: 400_000, disk: 500_000)
        history.add(Self.sample(at: Self.tenOClock, [(Self.safari, tiny), (Self.claude, Self.totals(cpu: 30))]))
        history.add(Self.sample(at: Self.tenOClock.addingTimeInterval(3_600), [(Self.safari, tiny)]))
        history.prune(now: Self.tenOClock.addingTimeInterval(3_700))
        #expect(history.hours[0].usage.keys.sorted() == [Self.claude.id])
        #expect(history.hours[0].measuredSeconds == 1)
        #expect(history.hours[1].usage.keys.sorted() == [Self.safari.id])
    }

    @Test func codingRoundTripsRoundedValues() throws {
        var history = AppUsageHistory()
        history.add(Self.sample(at: Self.tenOClock, [(Self.safari, Self.totals(cpu: 1.26, energy: 3.6, network: 10.4,
                                                                               disk: 7))]))
        let decoded = try AppUsageHistory.decode(try history.encoded())
        #expect(decoded.hours[0].usage[Self.safari.id] == Self.totals(cpu: 1.3, energy: 3.6, network: 10, disk: 7))
        #expect(decoded.subjects == history.subjects)
        #expect(decoded.hours[0].start == Self.tenOClock)
    }

    @Test func codingKeepsUnmeasuredValuesUnknown() throws {
        var history = AppUsageHistory()
        history.add(Self.sample(at: Self.tenOClock, network: false, [(Self.claude, Self.totals(cpu: 30))]))
        let decoded = try AppUsageHistory.decode(try history.encoded())
        #expect(decoded.hours[0].usage[Self.claude.id] == Self.totals(cpu: 30))
        #expect(decoded.hours[0].usage[Self.claude.id]?.networkBytes == nil)
        #expect(decoded.hours[0].usage[Self.claude.id]?.energyJoules == nil)
    }

    /// Dateien der Version 1 bleiben lesbar. Sie speicherten nicht Gemessenes als 0: Energie 0 gilt deshalb als nicht
    /// gemessen. Netzwerte stammen wie bei allen Dateien vor der Korrektur der Messzeitpunkte aus überhöhten Raten und
    /// gelten ebenfalls als nicht gemessen; alles andere bleibt.
    @Test func versionOneFilesLoadWithUnknownInsteadOfStoredZeros() throws {
        let json = """
            {"version":1,"subjects":{"process:claude":{"kind":"process","name":"claude"}},"hours":[
            {"start":1793959200,"measuredSeconds":60,"networkSeconds":0,"usage":{"process:claude":[30,0,0,0]}},
            {"start":1793962800,"measuredSeconds":60,"networkSeconds":60,"usage":{"process:claude":[30,12.5,0,7]}}]}
            """
        let history = try AppUsageHistory.decode(Data(json.utf8))
        #expect(history.hours.count == 2)
        #expect(history.hours[0].usage[Self.claude.id] == Self.totals(cpu: 30))
        #expect(history.hours[1].usage[Self.claude.id] == Self.totals(cpu: 30, energy: 12.5, disk: 7))
        #expect(history.hours.map(\.networkSeconds) == [0, 0])
        #expect(history.subjects[Self.claude.id] == Self.claude)
    }

    /// Bewertung 2026.11.7-1188, Mangel 2: Bis zur Korrektur der Messzeitpunkte waren alle gespeicherten Netzwerte um
    /// Größenordnungen überhöht (Orca 40 GB an einem Tag). Welche Takte betroffen waren, weiß die Datei nicht – Netz
    /// gilt in diesen Dateien deshalb als nicht gemessen. CPU, Energie, Datenträger, Messzeit und Gegenstände bleiben,
    /// die Datei bleibt Version 2 und damit für ältere Grantry-Versionen lesbar.
    @Test func networkValuesFromBeforeTimestampFixCountAsUnmeasured() throws {
        let json = """
            {"version":2,"subjects":{"process:claude":{"kind":"process","name":"claude"}},"hours":[
            {"start":1793959200,"measuredSeconds":3600,"networkSeconds":3500,"usage":{"process:claude":[120,40.5,40000000000,7]}},
            {"start":1793962800,"measuredSeconds":60,"networkSeconds":0,"usage":{"process:claude":[30,null,null,0]}}]}
            """
        let history = try AppUsageHistory.decode(Data(json.utf8))

        #expect(history.hours.map(\.start) == [Self.tenOClock, Self.tenOClock.addingTimeInterval(3_600)])
        #expect(history.hours.map(\.measuredSeconds) == [3_600, 60])
        #expect(history.hours.map(\.networkSeconds) == [0, 0])
        #expect(history.hours[0].usage[Self.claude.id] == Self.totals(cpu: 120, energy: 40.5, disk: 7))
        #expect(history.hours[1].usage[Self.claude.id] == Self.totals(cpu: 30))
        #expect(history.hours[0].total(.network) == nil)
        #expect(history.subjects[Self.claude.id] == Self.claude)
    }

    /// Nach der Korrektur gemessene Netzwerte bleiben beim Laden erhalten; die Datei bleibt Version 2.
    @Test func networkValuesMeasuredAfterTimestampFixSurviveReload() throws {
        var history = AppUsageHistory()
        history.add(Self.sample(at: Self.tenOClock, [(Self.claude, Self.totals(cpu: 1, network: 5_000))]))
        let data = try history.encoded()

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 2)
        let decoded = try AppUsageHistory.decode(data)
        #expect(decoded.hours[0].usage[Self.claude.id]?.networkBytes == 5_000)
        #expect(decoded.hours[0].networkSeconds == 1)
        #expect(decoded == history)
    }

    /// Eine Datei unbekannter Version (etwa von einer neueren Grantry) gilt nicht still als leer, sonst würde sie beim
    /// nächsten Speichern ersetzt (#353).
    @Test func unknownVersionIsAnError() {
        #expect(throws: AppUsageHistory.UnknownVersion(version: 99)) {
            try AppUsageHistory.decode(Data(#"{"version":99,"subjects":{},"hours":[]}"#.utf8))
        }
    }

    @Test func thirtyDaysStayBelowTwoMegabytes() throws {
        var history = AppUsageHistory()
        let subjects = (0..<40).map { index in
            AppUsageSubject(kind: .app, bundleID: "com.example.application\(index)", name: "Application \(index)",
                            bundlePath: "/Applications/Application \(index).app")
        }
        for hour in 0..<(30 * 24) {
            let usage = subjects.map { ($0, Self.totals(cpu: 1_234.5, energy: 98_765, network: 123_456_789,
                                                        disk: 987_654_321)) }
            history.add(Self.sample(at: Self.tenOClock.addingTimeInterval(Double(hour) * 3_600), seconds: 3_600,
                                    usage))
        }
        #expect(try history.encoded().count < 2_000_000)
    }

    @Test func totalsReadEachMetric() {
        let totals = Self.totals(cpu: 1, energy: 2, network: 3, disk: 4)
        #expect(AppUsageMetric.allCases.map { totals[$0] } == [1, 2, 3, 4])
    }
}
