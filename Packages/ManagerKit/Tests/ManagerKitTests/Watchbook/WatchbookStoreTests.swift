import Foundation
import Testing
@testable import ManagerKit

@Suite struct WatchbookStoreTests {
    private typealias Fixtures = WatchbookFixtures
    private let day = WatchbookFixtures.day
    private var start: Date { day.start }

    private func permissions(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func everything(in store: WatchbookStore) -> WatchbookRecords {
        store.records(in: Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 4_000_000_000))
    }

    // MARK: Schreiben und Lesen

    @Test func missingFolderReadsAsEmptyWithoutCreatingIt() throws {
        try Fixtures.withStore { store in
            let records = everything(in: store)
            #expect(records.points.isEmpty && records.events.isEmpty && records.problems.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        }
    }

    @Test func appendedRecordsReadBackAndArePrivate() throws {
        try Fixtures.withStore { store in
            let points = Fixtures.points(from: start, count: 3)
            let event = Fixtures.event(start: start, end: nil)
            let report = try store.append(points: points, events: [event])
            #expect(report.problems.isEmpty && report.writtenBytes > 0)
            let records = everything(in: store)
            #expect(records.points == points && records.events == [event])
            #expect(try permissions(of: Fixtures.url(of: day, in: store)) == 0o600)
            #expect(try permissions(of: store.directory) == 0o700)
        }
    }

    /// Eine Datei je Tag: Punkte über Mitternacht (UTC) verteilen sich auf zwei Dateien und lesen sich lückenlos.
    @Test func dayChangeStartsTheNextFile() throws {
        try Fixtures.withStore { store in
            let points = Fixtures.points(from: day.end.addingTimeInterval(-30), count: 6)
            try store.append(points: Array(points.prefix(2)), events: [])
            try store.append(points: Array(points.dropFirst(2)), events: [])
            #expect(try Fixtures.names(in: store) == ["2026-11-07.watchbook", "2026-11-08.watchbook"])
            #expect(everything(in: store).points == points)
        }
    }

    /// Ereignisse stehen in der Datei ihres Beginns; ihr Ende ersetzt den Beginn.
    @Test func eventEndIsFiledWithItsStart() throws {
        try Fixtures.withStore { store in
            let begun = Fixtures.event(start: day.end.addingTimeInterval(-60), end: nil)
            try store.append(points: [], events: [begun])
            try store.append(points: [], events: [begun.ended(at: day.end.addingTimeInterval(600))])
            #expect(try Fixtures.names(in: store) == [day.fileName])
            #expect(everything(in: store).events == [begun.ended(at: day.end.addingTimeInterval(600))])
        }
    }

    /// Ein laufender Befund von gestern erscheint auch im Zeitraum von heute.
    @Test func eventsFromEarlierDaysAppearWhileTheyOverlap() throws {
        try Fixtures.withStore { store in
            let ongoing = Fixtures.event(start: start.addingTimeInterval(-3_600), end: nil)
            try store.append(points: Fixtures.points(from: start, count: 1), events: [ongoing])
            let records = store.records(in: start.addingTimeInterval(7_200)..<start.addingTimeInterval(10_800))
            #expect(records.events == [ongoing] && records.points.isEmpty)
        }
    }

    @Test func recordsAreLimitedToTheRange() throws {
        try Fixtures.withStore { store in
            let points = Fixtures.points(from: start, count: 10)
            try store.append(points: points, events: [])
            let records = store.records(in: points[2].time..<points[5].time)
            #expect(records.points == Array(points[2..<5]))
        }
    }

    /// Nach einem Abbruch mitten im Anhängen fehlt der Datei der Zeilenumbruch; der nächste Block beginnt trotzdem
    /// auf einer eigenen Zeile.
    @Test func appendAfterATornLineStartsOnANewLine() throws {
        try Fixtures.withStore { store in
            let points = Fixtures.points(from: start, count: 2)
            try store.append(points: [points[0]], events: [])
            let handle = try FileHandle(forWritingTo: Fixtures.url(of: day, in: store))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("P\t10\t1,2".utf8))
            try handle.close()
            try store.append(points: [points[1]], events: [])
            let records = everything(in: store)
            #expect(records.points == points)
        }
    }

    // MARK: Defekte Dateien

    private func place(_ content: String, for day: WatchbookDay, in store: WatchbookStore) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: Fixtures.url(of: day, in: store))
    }

    /// Eine fremde oder beschädigte Datei wird beiseitegelegt statt ergänzt (#353); ihr Inhalt bleibt erhalten.
    @Test func foreignFileIsSetAsideInsteadOfAppended() throws {
        try Fixtures.withStore { store in
            try place("W\t9\nneuere Fassung\n", for: day, in: store)
            #expect(everything(in: store).problems == [.unreadable(name: day.fileName, reason: "unbekanntes Format")])
            let report = try store.append(points: Fixtures.points(from: start, count: 1), events: [])
            let aside = try #require(report.problems.first.flatMap {
                if case .setAside(let name) = $0 { name } else { nil }
            })
            #expect(aside.hasPrefix("2026-11-07.unreadable-") && aside.hasSuffix(".watchbook"))
            #expect(try String(contentsOf: store.directory.appending(path: aside), encoding: .utf8)
                == "W\t9\nneuere Fassung\n")
            #expect(everything(in: store).points.count == 1)
        }
    }

    /// Lässt sich die Datei nicht beiseitelegen (Ordner schreibgeschützt), bleibt sie unverändert.
    @Test func foreignFileThatCannotBeSetAsideStaysUntouched() throws {
        try Fixtures.withStore { store in
            try place("kein Wachbuch", for: day, in: store)
            let folder = store.directory.path
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }
            let report = try store.append(points: Fixtures.points(from: start, count: 1), events: [])
            guard case .unreadable(let name, _)? = report.problems.first else {
                Issue.record("\(report.problems)")
                return
            }
            #expect(name == day.fileName)
            #expect(try String(contentsOf: Fixtures.url(of: day, in: store), encoding: .utf8) == "kein Wachbuch")
        }
    }

    @Test func fileWithManyBrokenLinesIsSetAsideInsteadOfCompacted() throws {
        try Fixtures.withStore { store in
            let header = String(decoding: WatchbookFileFormat.encode(points: Fixtures.points(from: start, count: 1),
                                                                     minutes: [], events: [], of: day), as: UTF8.self)
            try place(header + String(repeating: "Datenmüll\n", count: 20), for: day, in: store)
            let result = try store.maintain(now: day.end.addingTimeInterval(86_400))
            #expect(result.problems.count == 1)
            #expect(try Fixtures.names(in: store).allSatisfy { $0.contains(".unreadable-") })
        }
    }

    // MARK: Verdichtung

    /// 24 h nach Ende des Tages werden seine Punkte atomar zu Minutenwerten; vorher bleiben sie 10-s-Punkte.
    @Test func dayIsCompactedToMinutes24HoursAfterItsEnd() throws {
        try Fixtures.withStore { store in
            let points = Fixtures.points(from: start, count: 12) { $0 < 6 ? 0.25 : 0.75 }
            let event = Fixtures.event(start: start, end: start.addingTimeInterval(30))
            try store.append(points: points, events: [event])
            try store.maintain(now: day.end.addingTimeInterval(86_399))
            #expect(everything(in: store).points == points)
            let before = try Fixtures.size(of: Fixtures.url(of: day, in: store))
            try store.maintain(now: day.end.addingTimeInterval(86_400))
            let records = everything(in: store)
            #expect(records.points.isEmpty)
            #expect(records.minutes.map(\.start) == [start, start.addingTimeInterval(60)])
            #expect(records.minutes.map { $0.mean[.cpuTotal] } == [0.25, 0.75])
            #expect(records.events == [event])
            #expect(try Fixtures.size(of: Fixtures.url(of: day, in: store)) < before)
            #expect(try permissions(of: Fixtures.url(of: day, in: store)) == 0o600)
            #expect(try Fixtures.names(in: store) == [day.fileName])
        }
    }

    // MARK: Aufbewahrung und Obergrenze

    /// Aufbewahrung 7 Tage (Entscheidung O2): ganze Tage, die älter sind, entfallen.
    @Test func daysOlderThanSevenDaysAreRemoved() throws {
        try Fixtures.withStore { store in
            for offset in 0..<10 {
                try store.append(points: Fixtures.points(from: start.addingTimeInterval(Double(offset) * 86_400),
                                                         count: 1), events: [])
            }
            let now = start.addingTimeInterval(9 * 86_400 + 3_600)
            try store.maintain(now: now)
            let days = try Fixtures.names(in: store).compactMap { WatchbookDay(fileName: $0)?.index }
            #expect(days == Array((day.index + 2)...(day.index + 9)))
            #expect(days.allSatisfy { WatchbookDay(index: $0).end > now.addingTimeInterval(-WatchbookStore.retention) })
        }
    }

    /// Harte Obergrenze: Älteste Tage gehen zuerst – nur so viele, bis die Grenze eingehalten ist.
    @Test func sizeLimitRemovesOldestDaysFirst() throws {
        try Fixtures.withStore { store in
            let days = (0..<4).map { WatchbookDay(index: day.index + $0) }
            for day in days { try store.append(points: Fixtures.points(from: day.start, count: 200), events: []) }
            let now = days[3].start.addingTimeInterval(60)
            try store.maintain(now: now)
            let sizes = try days.map { try Fixtures.size(of: Fixtures.url(of: $0, in: store)) }
            let limited = WatchbookStore(directory: store.directory, sizeLimit: sizes.reduce(0, +) - sizes[0])
            let result = try limited.maintain(now: now)
            #expect(try Fixtures.names(in: store) == days.dropFirst().map(\.fileName))
            #expect(result.totalSize == limited.sizeLimit)
            let tighter = WatchbookStore(directory: store.directory, sizeLimit: sizes[3])
            #expect(try tighter.maintain(now: now).totalSize == sizes[3])
            #expect(try Fixtures.names(in: store) == [days[3].fileName])
        }
    }

    /// Ist schon der neueste Tag allein zu groß, wird er vorzeitig verdichtet.
    @Test func sizeLimitCompactsTheNewestDayEarly() throws {
        try Fixtures.withStore(sizeLimit: 20_000) { store in
            try store.append(points: Fixtures.points(from: start, count: 300), events: [])
            let result = try store.maintain(now: start.addingTimeInterval(3_000))
            let records = everything(in: store)
            #expect(records.points.isEmpty && records.minutes.count == 50)
            #expect(result.totalSize <= 20_000)
        }
    }

    @Test func setAsideCopiesCountAgainstTheLimitAndGoFirst() throws {
        try Fixtures.withStore(sizeLimit: 30_000) { store in
            try place(String(repeating: "x", count: 15_000), for: WatchbookDay(index: day.index + 1), in: store)
            try store.append(points: Fixtures.points(from: start.addingTimeInterval(86_400), count: 1), events: [])
            try store.append(points: Fixtures.points(from: start, count: 200), events: [])
            try store.maintain(now: start.addingTimeInterval(86_400 + 60))
            let names = try Fixtures.names(in: store)
            #expect(names == [day.fileName, WatchbookDay(index: day.index + 1).fileName])
        }
    }

    @Test func setAsideCopiesExpireWithTheRetention() throws {
        try Fixtures.withStore { store in
            try place("kaputt", for: day, in: store)
            try store.append(points: Fixtures.points(from: start, count: 1), events: [])
            let aside = try #require(try Fixtures.names(in: store).first { $0.contains(".unreadable-") })
            let expired = Date().addingTimeInterval(-WatchbookStore.retention - 3_600)
            try FileManager.default.setAttributes([.modificationDate: expired],
                                                  ofItemAtPath: store.directory.appending(path: aside).path)
            try store.maintain(now: Date())
            #expect(try !Fixtures.names(in: store).contains(aside))
        }
    }

    @Test func maintenanceRemovesLeftoversOfInterruptedWrites() throws {
        try Fixtures.withStore { store in
            try store.append(points: Fixtures.points(from: start, count: 1), events: [])
            let leftover = store.directory.appending(path: ".\(day.fileName).\(UUID().uuidString)")
            try Data("Rest".utf8).write(to: leftover)
            try store.maintain(now: start)
            #expect(try Fixtures.names(in: store) == [day.fileName])
        }
    }

    // MARK: Löschen

    @Test func removeDeletesEverythingOfTheWatchbook() throws {
        try Fixtures.withStore { store in
            try place("kaputt", for: day, in: store)
            try store.append(points: Fixtures.points(from: start, count: 1), events: [])
            try Data("Rest".utf8).write(to: store.directory.appending(path: ".\(day.fileName).ABC"))
            try store.remove()
            #expect(!FileManager.default.fileExists(atPath: store.directory.path))
            #expect(everything(in: store).points.isEmpty)
        }
    }

    @Test func removeToleratesAMissingFolderAndKeepsForeignFiles() throws {
        try Fixtures.withStore { store in
            try store.remove()
            try store.append(points: Fixtures.points(from: start, count: 1), events: [])
            let foreign = store.directory.appending(path: "Notiz.txt")
            try Data("fremd".utf8).write(to: foreign)
            try store.remove()
            #expect(try Fixtures.names(in: store) == ["Notiz.txt"])
        }
    }

    // MARK: Datenschutz

    /// Abnahmekriterium 4: keine Befehlszeilen, keine Pfade und keine Programmnamen anderer Benutzer in der Datei.
    @Test func fileHoldsNoCommandLinesPathsOrForeignProgramNames() throws {
        try Fixtures.withStore { store in
            var snapshot = TaskManagerSnapshot()
            snapshot.processes = [
                ProcessMeasurement(key: ProcessKey(pid: 1_001, startTime: 1), parentPID: 1, uid: 501,
                                   name: "python3", cpuLoad: 0.25, memoryBytes: 300 << 20, diskReadPerSecond: nil,
                                   diskWritePerSecond: nil, threadCount: 1,
                                   executablePath: "/Users/bernd/.venv/bin/python3"),
                ProcessMeasurement(key: ProcessKey(pid: 1_002, startTime: 1), parentPID: 1, uid: 502,
                                   name: "Steuererklaerung-Anna", cpuLoad: 0.5, memoryBytes: 900 << 20,
                                   diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: 1,
                                   executablePath: "/Users/anna/Steuer/Steuererklaerung-Anna"),
                ProcessMeasurement(key: ProcessKey(pid: 1_003, startTime: 1), parentPID: 1, uid: 0,
                                   name: "backupd", cpuLoad: 0.125, memoryBytes: 100 << 20,
                                   diskReadPerSecond: nil, diskWritePerSecond: nil, threadCount: 1,
                                   executablePath: "/System/Library/CoreServices/backupd.bundle/backupd --geheim"),
            ]
            let point = WatchbookPoint(time: start, snapshot: snapshot, currentUID: 501, thermalState: .nominal,
                                       power: nil)
            let finding = WatchbookEvent(
                kind: .finding, type: "sustainedLoad", start: start, end: nil, tone: .finding,
                subject: WatchbookSubject(processNamed: "Steuererklaerung-Anna", uid: 502, currentUID: 501),
                summary: "Ein Programm eines anderen Kontos lastet die CPU aus")
            try store.append(points: [point], events: [finding])
            // 10-s-Punkte und Minutenwerte nach der Verdichtung.
            for compacted in [false, true] {
                if compacted { try store.maintain(now: day.end.addingTimeInterval(86_400)) }
                let text = try String(contentsOf: Fixtures.url(of: day, in: store), encoding: .utf8)
                for forbidden in ["Steuer", "Anna", "/", "--geheim", "bernd", ".venv", "CoreServices"] {
                    #expect(!text.contains(forbidden), "\(forbidden), verdichtet: \(compacted)")
                }
                #expect(text.contains("python3") && text.contains("backupd"))
            }
            let minute = try #require(everything(in: store).minutes.first)
            #expect(minute.cpuConsumers.map(\.subject)
                == [.otherAccounts, .program("python3"), .systemProcess("backupd")])
            #expect(everything(in: store).events.first?.subject == .otherAccounts)
        }
    }
}
