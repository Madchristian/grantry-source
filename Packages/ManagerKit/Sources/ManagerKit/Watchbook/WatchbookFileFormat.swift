import Foundation

/// Inhalt einer Tagesdatei.
struct WatchbookDayContents: Equatable, Sendable {
    var points: [WatchbookPoint] = []
    var minutes: [WatchbookMinute] = []
    /// Je `id` der zuletzt geschriebene Stand, in der Reihenfolge des ersten Auftretens.
    var events: [WatchbookEvent] = []
    /// Unlesbare Zeilen in Blöcken dieser Fassung, etwa eine beim Anhängen abgerissene.
    var brokenLineCount = 0
    /// Nichts Fremdes: Die Datei ist leer oder beginnt mit der Kopfzeile dieser Fassung und enthält keinen Block einer
    /// anderen. Nur eine solche Datei wird ergänzt oder verdichtet; jede andere legt der Speicher beiseite (#353).
    var isOwnFormat = true
}

/// Zeilenformat der Wachbuch-Dateien, Fassung 1 – eine Datei je UTC-Tag (`WatchbookDay`), UTF-8, je Zeile ein Eintrag,
/// Felder durch Tabulatoren getrennt:
///
/// ```
/// W  1                                      Kopfzeile eines Blocks; beginnt eine neue Namenstabelle
/// N  <Nr>  <o|s>  <Name>                    Name eines eigenen Programms (o) bzw. Systemprozesses (s)
/// P  <Sekunde>  <Werte>  <CPU>  <Speicher>  10-s-Punkt
/// M  <Sekunde>  <Punkte>  <Mittel>  <Maximum>  <CPU>  <Speicher>   Minutenwert
/// E  <ID>  <Gattung>  <Art>  <Beginn>  <Ende>  <Ton>  <Bezug>  <Text>  [<Prozess>]   Ereignis
/// ```
///
/// - `Sekunde`: seit Beginn des UTC-Tags; `Beginn`/`Ende`: seit 1970; jeweils auf 0,1 s, `Ende` leer = läuft noch.
/// - `Werte`, `Mittel`, `Maximum`: je Messgröße (`WatchbookMetric`, in deren Reihenfolge) ganze Schritte
///   (`WatchbookQuantum`), durch Kommas getrennt; leer heißt nicht gemessen. Fehlen hinten Messgrößen (Zeile aus der Zeit
///   vor ihnen, etwa die Leistung je Block vor TM-14.5), sind sie nicht gemessen.
/// - `CPU`, `Speicher`: bis zu drei `<Nr>:<Schritte>`, `*` statt der Nummer für „Andere Konten“; `Bezug`: `<Nr>`,
///   `*` oder leer. Nummern verweisen auf die Namenstabelle des Blocks – Namen stehen so je Block einmal statt in
///   jeder Zeile, und ein abgerissener Block stört keinen späteren.
/// - `Prozess`: `<PID>:<Startzeit in µs seit 1970>` des Verursachers (TM-12.6); fehlt das Feld (ältere Zeilen, kein
///   Prozess), gibt es keinen.
///
/// Jedes Anhängen schreibt einen eigenen Block. Unlesbare Zeilen werden übersprungen und gezählt; Zeilen nach der
/// Kopfzeile einer anderen Fassung oder ohne Kopfzeile davor werden nicht gelesen. Namen und Texte sind einzeilig
/// (`DisplayText.singleLine`), Tabulatoren kommen darin nicht vor.
enum WatchbookFileFormat {
    static let version = 1

    /// Ein Block mit Kopfzeile und eigener Namenstabelle.
    static func encode(points: [WatchbookPoint], minutes: [WatchbookMinute], events: [WatchbookEvent],
                       of day: WatchbookDay) -> [UInt8] {
        var writer = Writer(day: day)
        writer.line("W", "\(version)")
        for point in points { writer.point(point) }
        for minute in minutes { writer.minute(minute) }
        for event in events { writer.event(event) }
        return writer.bytes
    }

    /// Liest einen ganzen Dateiinhalt. `eventsOnly` überspringt Punkte und Minuten, ohne sie zu prüfen.
    static func decode(_ bytes: [UInt8], of day: WatchbookDay, eventsOnly: Bool = false) -> WatchbookDayContents {
        bytes.withUnsafeBufferPointer { buffer in
            var reader = Reader(buffer: buffer, day: day, eventsOnly: eventsOnly)
            reader.read()
            return reader.contents
        }
    }

    /// Ob `bytes` mit der Kopfzeile dieser Fassung beginnen (Prüfung vor dem Anhängen).
    static func startsWithOwnHeader(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: Array("W\t\(version)\n".utf8))
    }

    /// Größte Sekunde eines Tags in Zehntelsekunden.
    private static let tenthsPerDay: Int64 = 864_000
}

// MARK: - Schreiben

private extension WatchbookFileFormat {
    struct Writer {
        let day: WatchbookDay
        var bytes: [UInt8] = []
        private var numbers: [WatchbookSubject: Int] = [:]

        init(day: WatchbookDay) {
            self.day = day
        }

        mutating func line(_ fields: String...) { line(of: fields) }

        mutating func line(of fields: [String]) {
            bytes.append(contentsOf: fields.joined(separator: "\t").utf8)
            bytes.append(UInt8(ascii: "\n"))
        }

        mutating func point(_ point: WatchbookPoint) {
            let cpu = consumers(point.cpuConsumers, metric: .cpuTotal)
            let memory = consumers(point.memoryConsumers, metric: .memoryUsed)
            line("P", secondOfDay(point.time), values(point.values), cpu, memory)
        }

        mutating func minute(_ minute: WatchbookMinute) {
            let cpu = consumers(minute.cpuConsumers, metric: .cpuTotal)
            let memory = consumers(minute.memoryConsumers, metric: .memoryUsed)
            line("M", secondOfDay(minute.start), "\(max(minute.count, 1))", values(minute.mean),
                 values(minute.maximum), cpu, memory)
        }

        mutating func event(_ event: WatchbookEvent) {
            var subject = ""
            if let known = event.subject { subject = reference(known) }
            var fields = ["E", event.id.uuidString, event.kind.rawValue, event.type,
                          Self.tenths(event.start.timeIntervalSince1970),
                          event.end.map { Self.tenths($0.timeIntervalSince1970) } ?? "", event.tone?.rawValue ?? "",
                          subject, event.summary]
            if let process = event.process { fields.append("\(process.pid):\(process.startTime)") }
            line(of: fields)
        }

        /// Nummer des Gegenstands in der Namenstabelle; ein neuer Name wird vor seiner ersten Verwendung geschrieben.
        private mutating func reference(_ subject: WatchbookSubject) -> String {
            let kind: String
            switch subject {
            case .otherAccounts: return "*"
            case .program: kind = "o"
            case .systemProcess: kind = "s"
            }
            if let number = numbers[subject] { return "\(number)" }
            let number = numbers.count
            numbers[subject] = number
            line("N", "\(number)", kind, subject.name ?? "")
            return "\(number)"
        }

        private mutating func consumers(_ consumers: [WatchbookConsumer], metric: WatchbookMetric) -> String {
            consumers.filter { metric.quantum.fits($0.value) && $0.value >= 0 }.map {
                "\(reference($0.subject)):\(metric.quantum.steps($0.value))"
            }.joined(separator: ",")
        }

        private func values(_ values: WatchbookValues) -> String {
            WatchbookMetric.allCases.map { metric in values[metric].map { "\(metric.quantum.steps($0))" } ?? "" }
                .joined(separator: ",")
        }

        private func secondOfDay(_ time: Date) -> String {
            let tenths = ((time.timeIntervalSince(day.start)) * 10).rounded()
            return Self.text(ofTenths: Int64(min(max(tenths, 0), Double(WatchbookFileFormat.tenthsPerDay - 1))))
        }

        static func tenths(_ seconds: TimeInterval) -> String { text(ofTenths: Int64((seconds * 10).rounded())) }

        /// „123“ bzw. „123.4“.
        private static func text(ofTenths tenths: Int64) -> String {
            let whole = tenths / 10, fraction = abs(tenths % 10)
            return fraction == 0 ? "\(whole)" : "\(whole).\(fraction)"
        }
    }
}

// MARK: - Lesen

private extension WatchbookFileFormat {
    /// Liest Byte für Byte ohne Zwischen-Strings: Eine Woche hat rund 26 000 Zeilen, die Ansicht braucht sie in unter
    /// 150 ms (#380).
    struct Reader {
        private enum Block {
            /// Vor der ersten Kopfzeile bzw. nach der einer anderen Fassung: nicht lesen.
            case none, own, foreign
        }

        let buffer: UnsafeBufferPointer<UInt8>
        let day: WatchbookDay
        let eventsOnly: Bool
        private(set) var contents = WatchbookDayContents()
        private var block = Block.none
        private var names: [Int64: WatchbookSubject] = [:]
        private var eventIndex: [UUID: Int] = [:]

        init(buffer: UnsafeBufferPointer<UInt8>, day: WatchbookDay, eventsOnly: Bool) {
            self.buffer = buffer
            self.day = day
            self.eventsOnly = eventsOnly
        }

        mutating func read() {
            var start = 0
            var isFirstLine = true
            while start < buffer.count {
                let newline = index(of: UInt8(ascii: "\n"), in: start..<buffer.count)
                let line = start..<(newline ?? buffer.count)
                start = line.upperBound + 1
                guard !line.isEmpty else { continue }
                let isHeader = buffer[line.lowerBound] == UInt8(ascii: "W")
                    && (line.count == 1 || buffer[line.lowerBound + 1] == UInt8(ascii: "\t"))
                if isFirstLine, !isHeader { contents.isOwnFormat = false }
                isFirstLine = false
                if isHeader {
                    header(line)
                } else if block == .own {
                    if newline == nil || !entry(line) { contents.brokenLineCount += 1 }
                }
            }
        }

        private mutating func header(_ line: Range<Int>) {
            var fields = Fields(buffer: buffer, line: line)
            _ = fields.next()
            if let version = fields.next().flatMap(integer), version == WatchbookFileFormat.version,
               fields.next() == nil {
                block = .own
                names = [:]
            } else {
                block = .foreign
                contents.isOwnFormat = false
            }
        }

        /// `false`, wenn die Zeile unlesbar ist.
        private mutating func entry(_ line: Range<Int>) -> Bool {
            var fields = Fields(buffer: buffer, line: line)
            guard let tag = fields.next(), tag.count == 1 else { return false }
            switch buffer[tag.lowerBound] {
            case UInt8(ascii: "N"): return name(&fields)
            case UInt8(ascii: "E"): return event(&fields)
            case UInt8(ascii: "P"): return eventsOnly || point(&fields)
            case UInt8(ascii: "M"): return eventsOnly || minute(&fields)
            default: return false
            }
        }

        private mutating func name(_ fields: inout Fields) -> Bool {
            guard let number = fields.next().flatMap(integer), let kind = fields.next(), kind.count == 1,
                  let name = fields.next().map(string), !name.isEmpty, fields.next() == nil else { return false }
            switch buffer[kind.lowerBound] {
            case UInt8(ascii: "o"): names[number] = .program(name)
            case UInt8(ascii: "s"): names[number] = .systemProcess(name)
            default: return false
            }
            return true
        }

        private mutating func point(_ fields: inout Fields) -> Bool {
            guard let time = fields.next().flatMap(timeOfDay), let values = fields.next().flatMap(values),
                  let cpu = fields.next().flatMap({ consumers($0, metric: .cpuTotal) }),
                  let memory = fields.next().flatMap({ consumers($0, metric: .memoryUsed) }),
                  fields.next() == nil else { return false }
            contents.points.append(WatchbookPoint(time: time, values: values, cpuConsumers: cpu,
                                                  memoryConsumers: memory))
            return true
        }

        private mutating func minute(_ fields: inout Fields) -> Bool {
            guard let start = fields.next().flatMap(timeOfDay), let count = fields.next().flatMap(integer), count > 0,
                  count <= Int64(Int32.max), let mean = fields.next().flatMap(values),
                  let maximum = fields.next().flatMap(values),
                  let cpu = fields.next().flatMap({ consumers($0, metric: .cpuTotal) }),
                  let memory = fields.next().flatMap({ consumers($0, metric: .memoryUsed) }),
                  fields.next() == nil else { return false }
            contents.minutes.append(WatchbookMinute(start: start, count: Int(count), mean: mean, maximum: maximum,
                                                    cpuConsumers: cpu, memoryConsumers: memory))
            return true
        }

        private mutating func event(_ fields: inout Fields) -> Bool {
            guard let id = fields.next().flatMap({ UUID(uuidString: string($0)) }),
                  let kind = fields.next().flatMap({ WatchbookEvent.Kind(rawValue: string($0)) }),
                  let type = fields.next().map(string),
                  let start = fields.next().flatMap(tenths), let endField = fields.next(),
                  let toneField = fields.next(), let subjectField = fields.next(),
                  let summary = fields.next().map(string) else { return false }
            var process: ProcessKey?
            if let processField = fields.next() {
                guard let key = self.process(processField) else { return false }
                process = key
            }
            guard fields.next() == nil else { return false }
            let end = endField.isEmpty ? nil : tenths(endField)
            let tone = toneField.isEmpty ? nil : WatchbookEvent.Tone(rawValue: string(toneField))
            let subject = subjectField.isEmpty ? nil : self.subject(subjectField)
            guard endField.isEmpty || end != nil, toneField.isEmpty || tone != nil,
                  subjectField.isEmpty || subject != nil else { return false }
            let event = WatchbookEvent(id: id, kind: kind, type: type, start: Date(timeIntervalSince1970: start),
                                       end: end.map(Date.init(timeIntervalSince1970:)), tone: tone, subject: subject,
                                       process: process, summary: summary)
            if let index = eventIndex[id] {
                contents.events[index] = event
            } else {
                eventIndex[id] = contents.events.count
                contents.events.append(event)
            }
            return true
        }

        private func values(_ field: Range<Int>) -> WatchbookValues? {
            var values = WatchbookValues()
            var parts = Fields(buffer: buffer, line: field, separator: UInt8(ascii: ","))
            for metric in WatchbookMetric.allCases {
                guard let part = parts.next() else {
                    return metric.rawValue >= Self.firstAppendedMetric.rawValue ? values : nil
                }
                guard !part.isEmpty else { continue }
                guard let steps = integer(part) else { return nil }
                values[metric] = metric.quantum.value(steps)
            }
            return parts.next() == nil ? values : nil
        }

        /// Erste später angefügte Messgröße: Kürzere Wertelisten sind unlesbar.
        private static let firstAppendedMetric = WatchbookMetric.cpuPower

        private func consumers(_ field: Range<Int>, metric: WatchbookMetric) -> [WatchbookConsumer]? {
            guard !field.isEmpty else { return [] }
            var consumers: [WatchbookConsumer] = []
            var parts = Fields(buffer: buffer, line: field, separator: UInt8(ascii: ","))
            while let part = parts.next() {
                guard let colon = index(of: UInt8(ascii: ":"), in: part),
                      let steps = integer(colon + 1..<part.upperBound) else { return nil }
                // Ein Name aus einer abgerissenen Zeile fehlt: nur dieser Verbraucher entfällt.
                guard let subject = subject(part.lowerBound..<colon) else { continue }
                consumers.append(WatchbookConsumer(subject: subject, value: metric.quantum.value(steps)))
            }
            return consumers
        }

        private func subject(_ field: Range<Int>) -> WatchbookSubject? {
            if field.count == 1, buffer[field.lowerBound] == UInt8(ascii: "*") { return .otherAccounts }
            return integer(field).flatMap { names[$0] }
        }

        /// „<PID>:<Startzeit>“ mit PID über 0 und Startzeit ab 0.
        private func process(_ field: Range<Int>) -> ProcessKey? {
            guard let colon = index(of: UInt8(ascii: ":"), in: field),
                  let pid = integer(field.lowerBound..<colon).flatMap(Int32.init(exactly:)), pid > 0,
                  let startTime = integer(colon + 1..<field.upperBound).flatMap(UInt64.init(exactly:)) else {
                return nil
            }
            return ProcessKey(pid: pid, startTime: startTime)
        }

        private func timeOfDay(_ field: Range<Int>) -> Date? {
            guard let tenths = integerTenths(field), tenths >= 0, tenths < WatchbookFileFormat.tenthsPerDay else {
                return nil
            }
            return day.start.addingTimeInterval(Double(tenths) / 10)
        }

        private func tenths(_ field: Range<Int>) -> TimeInterval? {
            integerTenths(field).map { Double($0) / 10 }
        }

        /// „123“ oder „123.4“ in Zehnteln.
        private func integerTenths(_ field: Range<Int>) -> Int64? {
            guard let dot = index(of: UInt8(ascii: "."), in: field) else { return integer(field).map { $0 * 10 } }
            guard dot + 2 == field.upperBound, let whole = integer(field.lowerBound..<dot),
                  let fraction = integer(dot + 1..<field.upperBound) else { return nil }
            return whole * 10 + (whole < 0 ? -fraction : fraction)
        }

        /// Ganze Zahl mit optionalem Minus, höchstens 18 Ziffern.
        private func integer(_ field: Range<Int>) -> Int64? {
            var index = field.lowerBound
            let isNegative = index < field.upperBound && buffer[index] == UInt8(ascii: "-")
            if isNegative { index += 1 }
            guard index < field.upperBound, field.upperBound - index <= 18 else { return nil }
            var value: Int64 = 0
            while index < field.upperBound {
                let digit = buffer[index] &- UInt8(ascii: "0")
                guard digit < 10 else { return nil }
                value = value * 10 + Int64(digit)
                index += 1
            }
            return isNegative ? -value : value
        }

        private func string(_ field: Range<Int>) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: buffer[field]), as: UTF8.self)
        }

        private func index(of byte: UInt8, in range: Range<Int>) -> Int? {
            guard !range.isEmpty, let base = buffer.baseAddress,
                  let found = memchr(base + range.lowerBound, Int32(byte), range.count) else { return nil }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
    }

    /// Felder einer Zeile bzw. Teile eines Felds, ohne Kopien.
    struct Fields {
        let buffer: UnsafeBufferPointer<UInt8>
        let line: Range<Int>
        var separator = UInt8(ascii: "\t")
        private var position: Int?

        init(buffer: UnsafeBufferPointer<UInt8>, line: Range<Int>, separator: UInt8 = UInt8(ascii: "\t")) {
            self.buffer = buffer
            self.line = line
            self.separator = separator
            position = line.lowerBound
        }

        mutating func next() -> Range<Int>? {
            guard let start = position else { return nil }
            var end = start
            while end < line.upperBound, buffer[end] != separator { end += 1 }
            position = end < line.upperBound ? end + 1 : nil
            return start..<end
        }
    }
}
