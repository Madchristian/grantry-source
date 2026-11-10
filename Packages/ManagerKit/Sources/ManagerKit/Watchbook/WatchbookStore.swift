import Darwin
import Foundation
import GrantryShared

/// Warum ein Teil des Wachbuchs nicht gelesen oder ergänzt wurde (Muster `AppUsageLoadProblem`, #353).
public enum WatchbookProblem: LocalizedError, Hashable, Sendable {
    /// Die Datei war nicht lesbar und liegt jetzt unter `name` im selben Ordner; der Tag beginnt neu.
    case setAside(name: String)
    /// Die Datei ist nicht lesbar (fremdes Format, zu groß, nicht von Grantry). Sie wird nicht verändert; Neues für
    /// ihren Tag wird erst gespeichert, wenn sie sich beiseitelegen lässt.
    case unreadable(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .setAside(let name):
            "Eine Datei des Wachbuchs war nicht lesbar und wurde als „\(name)“ beiseitegelegt."
        case .unreadable(let name, let reason):
            "Die Datei „\(name)“ des Wachbuchs ist nicht lesbar (\(reason)) und bleibt unverändert."
        }
    }
}

/// Ergebnis von `WatchbookStore.append`.
public struct WatchbookAppendReport: Equatable, Sendable {
    public var writtenBytes = 0
    /// Tage, an deren Datei angehängt wurde.
    public var days: Set<WatchbookDay> = []
    public var problems: [WatchbookProblem] = []
}

/// Ergebnis von `WatchbookStore.maintain`.
public struct WatchbookMaintenance: Equatable, Sendable {
    /// Größe aller Dateien des Wachbuchs danach.
    public var totalSize = 0
    public var problems: [WatchbookProblem] = []
}

/// Gelesene Einträge eines Zeitraums.
public struct WatchbookRecords: Equatable, Sendable {
    /// Aufsteigend nach Zeit.
    public var points: [WatchbookPoint] = []
    public var minutes: [WatchbookMinute] = []
    /// Aufsteigend nach Beginn.
    public var events: [WatchbookEvent] = []
    public var problems: [WatchbookProblem] = []
}

/// Ablage des Wachbuchs (Spec 2026-11-08 §5.1, §4.5): eine Datei je UTC-Tag (`WatchbookDay`, Format
/// `WatchbookFileFormat`) im privaten Ordner `Watchbook/` – Ordner `0700` (`PrivateDirectory`), Dateien `0600`
/// (`PrivateFile`).
///
/// - **Schreiben:** Blöcke werden angehängt (`append`, gebündelt vom `WatchbookJournal`). Eine Datei, die nicht mit der
///   eigenen Kopfzeile beginnt oder nicht von Grantry stammt, wird nie ergänzt oder überschrieben, sondern
///   beiseitegelegt (`<Tag>.unreadable-<Zeitpunkt>.watchbook`, Muster `AppUsageStore`, #353).
/// - **Wartung** (`maintain`): 24 h nach dem Ende eines Tags werden seine Punkte atomar zu Minutenwerten (Mittel und
///   Maximum); Tage älter als 7 Tage (Entscheidung O2) und beiseitegelegte Dateien nach 7 Tagen entfallen; über der
///   harten Obergrenze von 20 MB gehen zuerst beiseitegelegte Dateien, dann die ältesten Tage. Reste abgebrochener
///   atomarer Schreibvorgänge (`.<Name>.<UUID>`) werden entfernt.
/// - **Lesen** (`records`, `series`) ändert nichts; eine abgerissene letzte Zeile (Schreiben läuft) wird übergangen.
/// - **Löschen** (`remove`): alle Dateien des Wachbuchs und der Ordner, sofern sonst nichts darin liegt.
///
/// Inhalt: Messwerte, Programmnamen eigener Programme und von Systemprozessen, sonst „Andere Konten“
/// (`WatchbookSubject`); nie Befehlszeilen oder Pfade. Synchron und ohne eigene Uhr: Zeitpunkte kommen vom Aufrufer,
/// der die Aufrufe außerhalb des Hauptthreads (QoS `utility`) ausführt.
public struct WatchbookStore: Sendable {
    public static let retention: TimeInterval = 7 * 86_400
    /// So lange nach dem Ende eines Tags bleiben seine 10-s-Punkte.
    public static let compactionDelay: TimeInterval = 86_400
    public static let defaultSizeLimit = 20 * 1_024 * 1_024
    /// Mehr unlesbare Zeilen deuten auf eine beschädigte Datei: Sie wird beiseitegelegt statt verdichtet.
    static let maximumBrokenLines = 10
    /// Größte Datei, die gelesen wird. Über der Obergrenze, damit ein allein zu großer neuester Tag noch vorzeitig
    /// verdichtet werden kann; eine noch größere wird beiseitegelegt und fällt dann unter die Obergrenze.
    private var maximumFileSize: Int { sizeLimit * 2 }
    static let foreignFormatReason = "unbekanntes Format"

    public let directory: URL
    /// Harte Obergrenze aller Dateien zusammen in Byte.
    public let sizeLimit: Int

    public init(directory: URL, sizeLimit: Int = defaultSizeLimit) {
        self.directory = directory
        self.sizeLimit = sizeLimit
    }

    // MARK: Schreiben

    /// Hängt `points` und `events` je Tag als einen Block an (Ereignisse an den Tag ihres Beginns, damit ein späteres
    /// Ende den Beginn ersetzt). Eine fremde Datei wird zuvor beiseitegelegt; geht das nicht, entfällt der Block für
    /// diesen Tag und der Bericht nennt das.
    @discardableResult
    public func append(points: [WatchbookPoint], events: [WatchbookEvent]) throws -> WatchbookAppendReport {
        var report = WatchbookAppendReport()
        guard !points.isEmpty || !events.isEmpty else { return report }
        let pointsByDay = Dictionary(grouping: points) { WatchbookDay(containing: $0.time) }
        let eventsByDay = Dictionary(grouping: events) { WatchbookDay(containing: $0.start) }
        let folder = try PrivateDirectory(at: directory)
        for day in Set(pointsByDay.keys).union(eventsByDay.keys).sorted() {
            let block = WatchbookFileFormat.encode(points: pointsByDay[day] ?? [], minutes: [],
                                                   events: eventsByDay[day] ?? [], of: day)
            let (written, problem) = try append(block, to: day, in: folder)
            report.writtenBytes += written
            if written > 0 { report.days.insert(day) }
            if let problem { report.problems.append(problem) }
        }
        return report
    }

    private func append(_ block: [UInt8], to day: WatchbookDay,
                        in folder: PrivateDirectory) throws -> (written: Int, problem: WatchbookProblem?) {
        let name = day.fileName
        folder.harden([name])
        var problem: WatchbookProblem?
        var target = try openForAppending(name, in: folder.bound)
        if case .foreign(let reason) = target {
            guard let aside = setAside(name, in: folder.bound) else {
                return (0, .unreadable(name: name, reason: reason))
            }
            problem = .setAside(name: aside)
            target = try openForAppending(name, in: folder.bound)
        }
        guard case .ready(let descriptor, let needsNewline) = target else {
            return (0, problem ?? .unreadable(name: name, reason: Self.foreignFormatReason))
        }
        defer { close(descriptor) }
        let bytes = needsNewline ? [UInt8(ascii: "\n")] + block : block
        try Self.write(bytes, to: descriptor)
        return (bytes.count, problem)
    }

    private enum AppendTarget {
        case ready(descriptor: Int32, needsNewline: Bool)
        case foreign(reason: String)
    }

    /// Öffnet die Tagesdatei zum Anhängen (`O_APPEND`, ohne Symlink-Auflösung) bzw. legt sie vertraulich an. Fremd
    /// ist sie, wenn sie die Prüfung als private Datei nicht besteht oder nicht mit der eigenen Kopfzeile beginnt;
    /// endet sie ohne Zeilenumbruch (Abbruch beim letzten Anhängen), beginnt der nächste Block auf einer neuen Zeile.
    private func openForAppending(_ name: String, in folder: BoundDirectory) throws -> AppendTarget {
        let flags = O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC
        let descriptor = openat(folder.descriptor, name, flags)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return .ready(descriptor: try PrivateFile.createConfidential(named: name, in: folder),
                                       needsNewline: false)
            case ELOOP: return .foreign(reason: PrivateFileRefusal.notRegularFile.localizedDescription)
            default: throw BoundDirectory.posixError()
            }
        }
        do {
            let info = try PrivateFile.check(descriptor, protection: .confidential)
            guard info.st_size > 0 else { return .ready(descriptor: descriptor, needsNewline: false) }
            guard WatchbookFileFormat.startsWithOwnHeader(try PrivateFile.read(descriptor, limit: 8)) else {
                close(descriptor)
                return .foreign(reason: Self.foreignFormatReason)
            }
            var last: UInt8 = 0
            guard pread(descriptor, &last, 1, info.st_size - 1) == 1 else { throw BoundDirectory.posixError() }
            return .ready(descriptor: descriptor, needsNewline: last != UInt8(ascii: "\n"))
        } catch let refusal as PrivateFileRefusal {
            close(descriptor)
            return .foreign(reason: refusal.localizedDescription)
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Schreibt `bytes` vollständig an das Ende (`O_APPEND`); bei `EINTR` wird wiederholt. Ohne `fsync`: Ein Abbruch
    /// kostet höchstens den letzten Block, und das Wachbuch soll im Hintergrund kaum Last erzeugen.
    private static func write(_ bytes: [UInt8], to descriptor: Int32) throws {
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress! + written, $0.count - written)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw count < 0 ? BoundDirectory.posixError() : POSIXError(.EIO) }
            written += count
        }
    }

    /// Benennt `name` in `<Tag>.unreadable-<Zeitpunkt>.watchbook` um, ohne etwas zu ersetzen, und setzt die
    /// Änderungszeit auf jetzt – die Aufbewahrung der Kopie zählt ab dem Beiseitelegen. `nil`, wenn das Umbenennen
    /// scheitert.
    private func setAside(_ name: String, in folder: BoundDirectory) -> String? {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateSeparator(.omitted))
        let aside = "\(name.dropLast(WatchbookDay.fileExtension.count + 1))\(Self.setAsideMarker)\(stamp)."
            + WatchbookDay.fileExtension
        guard renameatx_np(folder.descriptor, name, folder.descriptor, aside, UInt32(RENAME_EXCL)) == 0 else {
            return nil
        }
        utimensat(folder.descriptor, aside, nil, AT_SYMLINK_NOFOLLOW)
        return aside
    }

    // MARK: Wartung

    /// Verdichtet, hält Aufbewahrung und Obergrenze ein und räumt Reste ab (siehe Typbeschreibung). Legt keinen Ordner
    /// an; ohne Ordner gibt es nichts zu tun.
    @discardableResult
    public func maintain(now: Date) throws -> WatchbookMaintenance {
        var result = WatchbookMaintenance()
        switch DirectoryReader.entries(atPath: directory.path(percentEncoded: false)) {
        case .entries: break
        case .missing: return result
        case .unreadable(let reason):
            result.problems.append(.unreadable(name: directory.lastPathComponent, reason: reason))
            return result
        }
        let folder = try PrivateDirectory(at: directory)
        folder.hardenEntries { _, isDirectory in !isDirectory }
        let cutoff = now.addingTimeInterval(-Self.retention)
        for entry in try inventory(of: folder.bound) {
            switch entry.kind {
            case .leftover:
                try remove(entry.name, in: folder.bound)
            case .setAside where entry.modified < cutoff:
                try remove(entry.name, in: folder.bound)
            case .day(let day) where day.end <= cutoff:
                try remove(entry.name, in: folder.bound)
            case .day(let day) where day.end.addingTimeInterval(Self.compactionDelay) <= now:
                if let problem = try compact(day, in: folder.bound) { result.problems.append(problem) }
            default:
                break
            }
        }
        result.totalSize = try enforceSizeLimit(in: folder.bound, problems: &result.problems)
        return result
    }

    /// Ersetzt die Punkte des Tags atomar durch Minutenwerte (vorhandene Minuten und Ereignisse bleiben). Eine fremde
    /// oder stark beschädigte Datei wird stattdessen beiseitegelegt.
    private func compact(_ day: WatchbookDay, in folder: BoundDirectory) throws -> WatchbookProblem? {
        let contents: WatchbookDayContents
        switch read(day, in: folder, eventsOnly: false) {
        case .success(let read) where read.brokenLineCount <= Self.maximumBrokenLines:
            contents = read
        case .success:
            return setAsideProblem(day.fileName, reason: "beschädigt", in: folder)
        case .failure(let problem):
            guard case .unreadable(let name, let reason) = problem else { return problem }
            return setAsideProblem(name, reason: reason, in: folder)
        }
        guard !contents.points.isEmpty || contents.brokenLineCount > 0 else { return nil }
        let minutes = WatchbookCompaction.minutes(from: contents.points, merging: contents.minutes)
        try PrivateFile.writeAtomically(
            WatchbookFileFormat.encode(points: [], minutes: minutes, events: contents.events, of: day),
            named: day.fileName, in: folder)
        return nil
    }

    private func setAsideProblem(_ name: String, reason: String, in folder: BoundDirectory) -> WatchbookProblem {
        setAside(name, in: folder).map { .setAside(name: $0) } ?? .unreadable(name: name, reason: reason)
    }

    /// Hält die Obergrenze ein und liefert die Größe danach: zuerst beiseitegelegte Dateien (älteste zuerst), dann die
    /// ältesten Tage; der neueste bleibt. Ist er allein zu groß, wird er vorzeitig verdichtet und erst dann entfernt.
    private func enforceSizeLimit(in folder: BoundDirectory, problems: inout [WatchbookProblem]) throws -> Int {
        var entries = try inventory(of: folder)
        var total = entries.reduce(0) { $0 + $1.size }
        let copies = entries.filter { $0.kind == .setAside }.sorted { $0.modified < $1.modified }
        let days = entries.compactMap { entry in entry.day.map { (day: $0, entry: entry) } }.sorted { $0.day < $1.day }
        for copy in copies where total > sizeLimit {
            try remove(copy.name, in: folder)
            total -= copy.size
        }
        for (_, entry) in days.dropLast() where total > sizeLimit {
            try remove(entry.name, in: folder)
            total -= entry.size
        }
        guard total > sizeLimit, let newest = days.last else { return total }
        if let problem = try compact(newest.day, in: folder) { problems.append(problem) }
        entries = try inventory(of: folder)
        total = entries.reduce(0) { $0 + $1.size }
        if total > sizeLimit, let file = entries.first(where: { $0.day == newest.day }) {
            try remove(file.name, in: folder)
            total -= file.size
        }
        return total
    }

    // MARK: Lesen

    /// Punkte und Minuten, die in `range` fallen, und Ereignisse, die ihn berühren (auch aus früheren Tagen).
    public func records(in range: Range<Date>) -> WatchbookRecords {
        var records = WatchbookRecords()
        var events = WatchbookEventMerger()
        records.problems = scan(range) { contents in
            records.points += contents.points.filter { range.contains($0.time) }
            records.minutes += contents.minutes.filter {
                $0.start < range.upperBound && $0.start.addingTimeInterval(WatchbookMinute.duration) > range.lowerBound
            }
            events.add(contents.events)
        }
        records.points.sort { $0.time < $1.time }
        records.minutes.sort { $0.start < $1.start }
        records.events = events.overlapping(range)
        return records
    }

    /// Verdichtete Reihe für `period` bis `end` auf `width` Spalten (`WatchbookSeriesBuilder`); `pendingPoints` und
    /// `pendingEvents` sind noch nicht geschriebene Einträge des Journals.
    public func series(_ period: WatchbookPeriod, endingAt end: Date, width: Int,
                       pendingPoints: [WatchbookPoint] = [], pendingEvents: [WatchbookEvent] = []) -> WatchbookSeries {
        let range = end.addingTimeInterval(-period.duration)..<end
        var builder = WatchbookSeriesBuilder(range: range, width: width)
        var events = WatchbookEventMerger()
        let problems = scan(range) { contents in
            builder.add(contents.minutes)
            builder.add(contents.points)
            events.add(contents.events)
        }
        builder.add(pendingPoints)
        events.add(pendingEvents)
        return builder.build(events: events.overlapping(range), problems: problems)
    }

    /// Nur die Ereignisse, die `range` berühren, ohne Punkte und Minuten zu lesen (`WatchbookStore.events(around:)`).
    func events(in range: Range<Date>) -> [WatchbookEvent] {
        var events = WatchbookEventMerger()
        _ = scan(range, eventsOnly: true) { events.add($0.events) }
        return events.overlapping(range)
    }

    /// Liest die Tage, deren Einträge in `range` reichen können, ganz und von allen übrigen nur die Ereignisse – ein
    /// laufender Befund kann an einem früheren Tag begonnen haben. Mit `eventsOnly` von allen Tagen nur die Ereignisse.
    /// Aufsteigend nach Tag; liefert die Probleme.
    private func scan(_ range: Range<Date>, eventsOnly: Bool = false,
                      _ visit: (WatchbookDayContents) -> Void) -> [WatchbookProblem] {
        let folder: BoundDirectory
        do {
            folder = try PrivateFile.trustedDirectory(at: directory.path(percentEncoded: false))
        } catch let error as POSIXError where error.code == .ENOENT {
            return []
        } catch {
            return [.unreadable(name: directory.lastPathComponent, reason: error.readableDescription)]
        }
        let first = WatchbookDay(containing: range.lowerBound.addingTimeInterval(-WatchbookMinute.duration))
        let last = WatchbookDay(containing: range.upperBound.addingTimeInterval(WatchbookPoint.maximumCoverage))
        var problems: [WatchbookProblem] = []
        let days: [WatchbookDay]
        do {
            days = try inventory(of: folder).compactMap(\.day).sorted()
        } catch {
            return [error as? WatchbookProblem
                ?? .unreadable(name: directory.lastPathComponent, reason: error.readableDescription)]
        }
        for day in days {
            switch read(day, in: folder, eventsOnly: eventsOnly || !(first...last).contains(day)) {
            case .success(let contents): visit(contents)
            case .failure(let problem): problems.append(problem)
            }
        }
        return problems
    }

    /// Liest eine Tagesdatei: reguläre Datei des Benutzers, für andere nicht änderbar, höchstens `maximumFileSize`
    /// groß, im eigenen Format. Eine fehlende ist leer.
    private func read(_ day: WatchbookDay, in folder: BoundDirectory,
                      eventsOnly: Bool) -> Result<WatchbookDayContents, WatchbookProblem> {
        let name = day.fileName
        let descriptor = openat(folder.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            return code == ENOENT ? .success(WatchbookDayContents())
                : .failure(.unreadable(name: name, reason: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                    .readableDescription))
        }
        defer { close(descriptor) }
        do {
            let info = try PrivateFile.check(descriptor, protection: .writeProtected)
            guard info.st_size <= maximumFileSize else {
                return .failure(.unreadable(name: name, reason: RegularFileReader.sizeLimitText(maximumFileSize)))
            }
            let contents = WatchbookFileFormat.decode(try Self.readAll(descriptor, size: Int(info.st_size)), of: day,
                                                      eventsOnly: eventsOnly)
            guard contents.isOwnFormat else {
                return .failure(.unreadable(name: name, reason: Self.foreignFormatReason))
            }
            return .success(contents)
        } catch {
            return .failure(.unreadable(name: name, reason: error.readableDescription))
        }
    }

    /// Liest bis zu `size` Bytes ab Offset 0; was danach angehängt wird, bleibt für das nächste Lesen.
    private static func readAll(_ descriptor: Int32, size: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        var count = 0
        while count < size {
            let chunk = bytes.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress! + count, size - count, off_t(count))
            }
            if chunk < 0, errno == EINTR { continue }
            guard chunk >= 0 else { throw BoundDirectory.posixError() }
            guard chunk > 0 else { break }
            count += chunk
        }
        return Array(bytes.prefix(count))
    }

    // MARK: Löschen

    /// „Wachbuch löschen“: Tagesdateien, beiseitegelegte Dateien und Reste; danach der Ordner, sofern er leer ist.
    /// Fremde Dateien im Ordner bleiben. Ein fehlender Ordner ist kein Fehler.
    public func remove() throws {
        let folder: BoundDirectory
        do {
            folder = try PrivateFile.trustedDirectory(at: directory.path(percentEncoded: false))
        } catch let error as POSIXError where error.code == .ENOENT {
            return
        }
        for entry in try inventory(of: folder) where entry.kind != .other {
            try remove(entry.name, in: folder)
        }
        rmdir(directory.path(percentEncoded: false))
    }

    // MARK: Ordnerinhalt

    static let setAsideMarker = ".unreadable-"

    private struct Entry {
        enum Kind: Equatable {
            case day(WatchbookDay)
            /// Beiseitegelegte Datei.
            case setAside
            /// Zwischendatei eines abgebrochenen atomaren Schreibens.
            case leftover
            case other
        }

        let name: String
        let kind: Kind
        let size: Int
        let modified: Date

        var day: WatchbookDay? {
            if case .day(let day) = kind { day } else { nil }
        }
    }

    /// Einträge des Ordners mit Art, Größe und Änderungszeit (ohne Symlink-Auflösung); Ordner und Symlinks zählen als
    /// fremd.
    private func inventory(of folder: BoundDirectory) throws -> [Entry] {
        let names: [String]
        switch DirectoryReader.entries(atPath: folder.path) {
        case .entries(let found): names = found
        case .missing: return []
        case .unreadable(let reason):
            throw WatchbookProblem.unreadable(name: directory.lastPathComponent, reason: reason)
        }
        return names.compactMap { name in
            var info = stat()
            guard fstatat(folder.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            let isFile = (info.st_mode & S_IFMT) == S_IFREG
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            return Entry(name: name, kind: isFile ? Self.kind(of: name) : .other, size: Int(info.st_size),
                         modified: modified)
        }
    }

    private static func kind(of name: String) -> Entry.Kind {
        if let day = WatchbookDay(fileName: name) { return .day(day) }
        let suffix = "." + WatchbookDay.fileExtension
        // `<Tag>.unreadable-<Zeitpunkt>.watchbook`
        if name.hasSuffix(suffix), let marker = name.range(of: setAsideMarker),
           WatchbookDay(fileName: String(name[..<marker.lowerBound]) + suffix) != nil {
            return .setAside
        }
        // `.<Tag>.watchbook.<UUID>` (`PrivateFile.writeAtomically`)
        if name.hasPrefix("."), let end = name.range(of: suffix + "."),
           WatchbookDay(fileName: String(name[name.index(after: name.startIndex)..<end.upperBound].dropLast())) != nil {
            return .leftover
        }
        return .other
    }

    private func remove(_ name: String, in folder: BoundDirectory) throws {
        guard unlinkat(folder.descriptor, name, 0) == 0 || errno == ENOENT else { throw BoundDirectory.posixError() }
    }
}

/// Führt Ereigniseinträge zusammen: je `id` gilt der zuletzt hinzugefügte Stand.
struct WatchbookEventMerger {
    private var events: [UUID: WatchbookEvent] = [:]

    mutating func add(_ entries: [WatchbookEvent]) {
        for event in entries { events[event.id] = event }
    }

    /// Ereignisse, die `range` berühren, aufsteigend nach Beginn (bei Gleichstand nach `id`).
    func overlapping(_ range: Range<Date>) -> [WatchbookEvent] {
        events.values.filter { $0.overlaps(range) }.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.id.uuidString < $1.id.uuidString
        }
    }
}
