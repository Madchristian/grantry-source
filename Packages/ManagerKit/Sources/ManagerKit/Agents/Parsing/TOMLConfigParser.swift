/// TOML-1.0-Teilmenge (wie Codex sie schreibt) in einen `ConfigValue`: Tabellen und Arrays von Tabellen, punktierte und
/// quotierte Schlüssel, alle vier String-Arten, Zahlen, Bools, Datum/Zeit (als Text), Arrays, Inline-Tabellen.
///
/// **Schwärzung:** Werte, deren Schlüsselpfad (Tabellenkopf plus Schlüssel, `nil` je Array-Ebene) `redaction` schwärzt,
/// werden nur syntaktisch geprüft und nie gesammelt (`ConfigValue.redacted`). Die Tabellenform darunter bleibt erhalten:
/// Schlüsselnamen bleiben sichtbar, auch bei `[[env]]` als Array von Tabellen. Ein Array aus Werten
/// (`env = ["a"]`) wird dagegen als Ganzes zu `.redacted`.
///
/// **Fehler:** Doppelte Schlüssel und doppelt definierte Tabellen sind Fehler. Fehlertexte nennen nie Schlüsselnamen
/// oder Werte, nur die Art des Problems und die Zeile (bei Duplikaten die des zweiten Vorkommens).
///
/// **Grenzen:** Wertetiefe (Arrays, Inline-Tabellen) und die Länge eines Schlüsselpfads (Tabellenkopf plus Schlüssel
/// plus Schlüssel umgebender Inline-Tabellen) sind je auf `maximumDepth` begrenzt, damit präparierte Dateien den Stack
/// nicht sprengen. Der Baum wird damit höchstens `2 * maximumDepth` Ebenen tief.
///
/// **Tolerierte Abweichungen von TOML 1.0** (der Parser liest Konfigurationen, er validiert sie nicht): Zahlen und
/// Datum/Zeit werden nur grob geprüft (Ziffernstart, erlaubte Zeichen – `1__2` oder `12abc` gehen durch), Steuerzeichen
/// in Strings und Kommentaren werden nicht beanstandet, und eine per punktiertem Schlüssel angelegte Tabelle
/// (`a.b = 1`) lässt sich nachträglich mit `[a]` öffnen.
///
/// Ein Parser wird einmal angelegt und mit `parseDocument()` genau einmal benutzt: `root` und `current` sind
/// Klassen, eine Kopie des Structs teilte sich den Tabellenzustand mit dem Original.
struct TOMLConfigParser {
    /// Wie beim JSON-Parser bewusst klein: Echte Konfigurationen verschachteln kaum über zehn Ebenen, die rekursive
    /// Auswertung soll auch auf Hintergrund-Threads (512 KB Stack) im Debug-Build sicher bleiben.
    static let maximumDepth = 64

    private var cursor: ByteCursor
    private let redaction: ConfigRedaction
    private let root = TOMLTable()
    private var current: TOMLTable
    /// Pfad von `current`; `nil` hinter einem Array von Tabellen (sein jeweils letztes Element).
    private var currentPath: [String?] = []
    /// Schlüssel des letzten Tabellenkopfs (ohne Array-Ebenen) – für `layout`.
    private var currentHeader: [String] = []
    /// Ob `layout` geführt wird (Stufe 2: Editor); beim Scan nicht.
    private let recordsLayout: Bool
    /// Anweisungen in Dokumentreihenfolge – nur Byte-Positionen und Schlüssel, nie Werte.
    private(set) var layout = TOMLLayout()

    init(bytes: [UInt8], redaction: ConfigRedaction, recordsLayout: Bool = false) {
        cursor = ByteCursor(bytes: bytes)
        self.redaction = redaction
        self.recordsLayout = recordsLayout
        current = root
    }

    mutating func parseDocument() throws(ConfigParseError) -> ConfigValue {
        while true {
            let lineStart = cursor.index
            skipSpaces()
            guard let byte = cursor.current else { break }
            switch byte {
            case UInt8(ascii: "\n"):
                cursor.advance()
            case UInt8(ascii: "\r"):
                try expectLineEnd()
            case UInt8(ascii: "#"):
                skipComment()
            case UInt8(ascii: "["):
                let isArray = try parseTableHeader()
                guard recordsLayout else { continue }
                layout.statements.append(TOMLStatement(kind: isArray ? .arrayTable : .table, path: currentHeader,
                                                       tablePath: currentHeader, range: lineStart..<cursor.index, valueRange: nil))
            default:
                let parsed = try parseKeyValue(into: current, path: currentPath, depth: 0)
                try expectLineEnd()
                guard recordsLayout else { continue }
                layout.statements.append(TOMLStatement(kind: .keyValue, path: currentHeader + parsed.keys, tablePath: currentHeader,
                                                       range: lineStart..<cursor.index, valueRange: parsed.value))
            }
        }
        return root.value
    }

    // MARK: Tabellen

    /// Liest `[kopf]` bzw. `[[kopf]]` samt Zeilenende; `true` bei einem Array von Tabellen.
    private mutating func parseTableHeader() throws(ConfigParseError) -> Bool {
        cursor.advance()
        let isArray = cursor.current == UInt8(ascii: "[")
        if isArray { cursor.advance() }
        skipSpaces()
        let path = try parseKey()
        skipSpaces()
        guard cursor.current == UInt8(ascii: "]") else { throw cursor.error("„]“ erwartet") }
        cursor.advance()
        if isArray {
            guard cursor.current == UInt8(ascii: "]") else { throw cursor.error("„]]“ erwartet") }
            cursor.advance()
        }
        var tablePath: [String?] = []
        let parent = try descend(from: root, along: path.dropLast(), path: &tablePath)
        let name = path[path.count - 1]
        tablePath.append(name)
        if isArray {
            guard let table = parent.appendTable(to: name) else { throw cursor.error("Tabelle schon anders definiert") }
            current = table
            tablePath.append(nil)
        } else {
            switch parent.entry(name) {
            case nil:
                let table = TOMLTable()
                table.isExplicit = true
                parent.set(name, .table(table))
                current = table
            case .table(let table)? where !table.isExplicit:
                table.isExplicit = true
                current = table
            default:
                throw cursor.error("Tabelle doppelt definiert")
            }
        }
        currentPath = tablePath
        currentHeader = path
        // Erst jetzt: Fehler oben sollen die Zeile des Kopfes nennen, nicht die der folgenden.
        try expectLineEnd()
        return isArray
    }

    /// Folgt `keys` ab `table` und legt fehlende Tabellen implizit an; ein Array von Tabellen führt zu seinem letzten
    /// Element. Hängt die Schlüssel an `path` an, hinter einem Array von Tabellen zusätzlich `nil`.
    private func descend(
        from table: TOMLTable, along keys: some Collection<String>, path: inout [String?]
    ) throws(ConfigParseError) -> TOMLTable {
        var table = table
        for key in keys {
            path.append(key)
            switch table.entry(key) {
            case nil:
                let next = TOMLTable()
                table.set(key, .table(next))
                table = next
            case .table(let next)?:
                table = next
            case .tables(let list)?:
                table = list[list.count - 1]
                path.append(nil)
            case .value?:
                throw cursor.error("Schlüssel ist keine Tabelle")
            }
        }
        return table
    }

    // MARK: Schlüssel und Werte

    /// `schlüssel = wert` in `table`. `path` ist der Pfad von `table`, `depth` die Wertetiefe (Inline-Tabellen sind Werte).
    /// Liefert die Schlüssel und die Lage des Werts (für `layout`).
    @discardableResult
    private mutating func parseKeyValue(
        into table: TOMLTable, path: [String?], depth: Int
    ) throws(ConfigParseError) -> (keys: [String], value: Range<Int>) {
        let keys = try parseKey()
        skipSpaces()
        guard cursor.current == UInt8(ascii: "=") else { throw cursor.error("„=“ erwartet") }
        cursor.advance()
        skipSpaces()
        // Die Grenze zählt nur Schlüssel; Array-Ebenen begrenzt die Wertetiefe.
        try checkPathLength(path.count { $0 != nil } + keys.count)
        // Ziel und Duplikat vor dem Wert prüfen: Der Fehler nennt so die Zeile des Schlüssels, nicht das Ende eines
        // mehrzeiligen Werts. Der Wert berührt `target` nicht (Inline-Tabellen bekommen eine eigene Tabelle).
        var fullPath = path
        let target = try descend(from: table, along: keys.dropLast(), path: &fullPath)
        let name = keys[keys.count - 1]
        fullPath.append(name)
        guard target.entry(name) == nil else { throw cursor.error("Schlüssel doppelt definiert") }
        let valueStart = cursor.index
        let value = try parseValue(path: fullPath, depth: depth)
        target.set(name, .value(value))
        return (keys, valueStart..<cursor.index)
    }

    private mutating func parseKey() throws(ConfigParseError) -> [String] {
        var keys = [try parseSimpleKey()]
        while true {
            skipSpaces()
            guard cursor.current == UInt8(ascii: ".") else { return keys }
            cursor.advance()
            skipSpaces()
            keys.append(try parseSimpleKey())
            try checkPathLength(keys.count)
        }
    }

    private mutating func parseSimpleKey() throws(ConfigParseError) -> String {
        switch cursor.current {
        case UInt8(ascii: "\""): return try scanBasicString(collect: true)
        case UInt8(ascii: "'"): return try scanLiteralString(collect: true)
        default:
            let start = cursor.index
            while let byte = cursor.current, Self.isBareKeyByte(byte) { cursor.advance() }
            guard cursor.index > start else { throw cursor.error("Schlüssel erwartet") }
            return String(decoding: cursor.bytes[start..<cursor.index], as: UTF8.self)
        }
    }

    /// Schlüsselpfade werden zu verschachtelten Tabellen und damit rekursiv ausgewertet – daher gilt dieselbe Grenze wie
    /// bei Werten.
    private func checkPathLength(_ count: Int) throws(ConfigParseError) {
        guard count <= Self.maximumDepth else { throw cursor.error("Zu tief verschachtelt") }
    }

    private mutating func parseValue(path: [String?], depth: Int) throws(ConfigParseError) -> ConfigValue {
        guard depth < Self.maximumDepth else { throw cursor.error("Zu tief verschachtelt") }
        let redacted = redaction.redacts(path: path)
        guard let byte = cursor.current else { throw cursor.error("Wert erwartet") }
        switch byte {
        case UInt8(ascii: "\""):
            let string = cursor.hasPrefix("\"\"\"")
                ? try scanMultilineBasicString(collect: !redacted) : try scanBasicString(collect: !redacted)
            return redacted ? .redacted : .string(string)
        case UInt8(ascii: "'"):
            let string = cursor.hasPrefix("'''")
                ? try scanMultilineLiteralString(collect: !redacted) : try scanLiteralString(collect: !redacted)
            return redacted ? .redacted : .string(string)
        case UInt8(ascii: "["):
            let elements = try parseArray(path: path, depth: depth)
            return redacted ? .redacted : .array(elements)
        case UInt8(ascii: "{"):
            return try parseInlineTable(path: path, depth: depth)
        default:
            return try scanScalar(collect: !redacted)
        }
    }

    private mutating func parseArray(path: [String?], depth: Int) throws(ConfigParseError) -> [ConfigValue] {
        cursor.advance()
        let elementPath = path + [nil]
        var elements: [ConfigValue] = []
        while true {
            try skipArrayTrivia()
            if cursor.current == UInt8(ascii: "]") {
                cursor.advance()
                return elements
            }
            elements.append(try parseValue(path: elementPath, depth: depth + 1))
            try skipArrayTrivia()
            switch cursor.current {
            case UInt8(ascii: ","): cursor.advance()
            case UInt8(ascii: "]"):
                cursor.advance()
                return elements
            default: throw cursor.error("„,“ oder „]“ erwartet")
            }
        }
    }

    private mutating func parseInlineTable(path: [String?], depth: Int) throws(ConfigParseError) -> ConfigValue {
        cursor.advance()
        let table = TOMLTable()
        skipSpaces()
        if cursor.current == UInt8(ascii: "}") {
            cursor.advance()
            return table.value
        }
        while true {
            skipSpaces()
            try parseKeyValue(into: table, path: path, depth: depth + 1)
            skipSpaces()
            switch cursor.current {
            case UInt8(ascii: ","): cursor.advance()
            case UInt8(ascii: "}"):
                cursor.advance()
                return table.value
            default: throw cursor.error("„,“ oder „}“ erwartet")
            }
        }
    }

    /// Bool, Zahl oder Datum/Zeit. Ein Datum mit Leerzeichen vor der Uhrzeit (`1979-05-27 07:32:00`) zählt als ein Wert.
    /// Mit `collect == false` wird der Wert nur geprüft und nicht materialisiert (Ergebnis `.redacted`).
    private mutating func scanScalar(collect: Bool) throws(ConfigParseError) -> ConfigValue {
        let start = cursor.index
        scanScalarToken()
        if Self.isDate(cursor.bytes[start..<cursor.index]), cursor.current == UInt8(ascii: " "),
           ByteCursor.isDigit(cursor.peek(1)), ByteCursor.isDigit(cursor.peek(2)), cursor.peek(3) == UInt8(ascii: ":") {
            cursor.advance()
            scanScalarToken()
        }
        let token = cursor.bytes[start..<cursor.index]
        guard !token.isEmpty else { throw cursor.error("Wert erwartet") }
        let isBool = token.elementsEqual("true".utf8) || token.elementsEqual("false".utf8)
        guard isBool || Self.isNumberOrDateToken(token) else { throw cursor.error("Ungültiger Wert") }
        guard collect else { return .redacted }
        let text = String(decoding: token, as: UTF8.self)
        if isBool { return .bool(token.count == 4) }
        let isDateTime = token.contains(UInt8(ascii: ":")) || Self.isDate(token.prefix(10))
        return isDateTime ? .string(text) : .number(text)
    }

    private mutating func scanScalarToken() {
        while let byte = cursor.current, !Self.endsScalar(byte) { cursor.advance() }
    }

    // MARK: Strings

    private mutating func scanBasicString(collect: Bool) throws(ConfigParseError) -> String {
        cursor.advance()
        var buffer: [UInt8] = []
        while true {
            guard let byte = cursor.current, byte != UInt8(ascii: "\n") else { throw cursor.error("String nicht abgeschlossen") }
            cursor.advance()
            switch byte {
            case UInt8(ascii: "\""):
                return collect ? String(decoding: buffer, as: UTF8.self) : ""
            case UInt8(ascii: "\\"):
                let scalar = try scanEscape()
                if collect { buffer.appendScalar(scalar) }
            default:
                if collect { buffer.append(byte) }
            }
        }
    }

    private mutating func scanMultilineBasicString(collect: Bool) throws(ConfigParseError) -> String {
        cursor.advance(3)
        skipNewline()
        var buffer: [UInt8] = []
        while true {
            if let extraQuotes = try scanMultilineClosing(quote: UInt8(ascii: "\"")) {
                if collect { buffer.append(contentsOf: repeatElement(UInt8(ascii: "\""), count: extraQuotes)) }
                return collect ? String(decoding: buffer, as: UTF8.self) : ""
            }
            guard let byte = cursor.current else { throw cursor.error("String nicht abgeschlossen") }
            cursor.advance()
            if byte == UInt8(ascii: "\\") {
                if Self.isLineContinuation(cursor) {
                    while let next = cursor.current, Self.isWhitespaceOrNewline(next) { cursor.advance() }
                    continue
                }
                let scalar = try scanEscape()
                if collect { buffer.appendScalar(scalar) }
            } else if collect {
                buffer.append(byte)
            }
        }
    }

    private mutating func scanLiteralString(collect: Bool) throws(ConfigParseError) -> String {
        cursor.advance()
        let start = cursor.index
        while cursor.current != UInt8(ascii: "'") {
            guard let byte = cursor.current, byte != UInt8(ascii: "\n") else { throw cursor.error("String nicht abgeschlossen") }
            cursor.advance()
        }
        let end = cursor.index
        cursor.advance()
        return collect ? String(decoding: cursor.bytes[start..<end], as: UTF8.self) : ""
    }

    private mutating func scanMultilineLiteralString(collect: Bool) throws(ConfigParseError) -> String {
        cursor.advance(3)
        skipNewline()
        let start = cursor.index
        while true {
            let contentEnd = cursor.index
            if let extraQuotes = try scanMultilineClosing(quote: UInt8(ascii: "'")) {
                return collect ? String(decoding: cursor.bytes[start..<(contentEnd + extraQuotes)], as: UTF8.self) : ""
            }
            guard !cursor.isAtEnd else { throw cursor.error("String nicht abgeschlossen") }
            cursor.advance()
        }
    }

    /// Prüft, ob am Cursor der Abschluss eines mehrzeiligen Strings steht. Ab drei gleichen Anführungszeichen in Folge
    /// schließt der String, bis zu zwei weitere gehören noch zum Inhalt (`"""x"""""` ergibt `x""`). Rückt hinter den
    /// ganzen Lauf und liefert die Zahl der Anführungszeichen, die zum Inhalt gehören; `nil`, wenn hier kein Abschluss
    /// steht. Mehr als fünf in Folge sind ungültig.
    private mutating func scanMultilineClosing(quote: UInt8) throws(ConfigParseError) -> Int? {
        var run = 0
        while cursor.peek(run) == quote { run += 1 }
        guard run >= 3 else { return nil }
        guard run <= 5 else { throw cursor.error("Zu viele Anführungszeichen") }
        cursor.advance(run)
        return run - 3
    }

    private mutating func scanEscape() throws(ConfigParseError) -> UInt32 {
        guard let byte = cursor.current else { throw cursor.error("String nicht abgeschlossen") }
        cursor.advance()
        switch byte {
        case UInt8(ascii: "b"): return 0x08
        case UInt8(ascii: "t"): return 0x09
        case UInt8(ascii: "n"): return 0x0A
        case UInt8(ascii: "f"): return 0x0C
        case UInt8(ascii: "r"): return 0x0D
        case UInt8(ascii: "e"): return 0x1B
        case UInt8(ascii: "\""): return 0x22
        case UInt8(ascii: "\\"): return 0x5C
        case UInt8(ascii: "u"):
            guard let value = cursor.readHex(count: 4) else { throw cursor.error("Ungültige \\u-Folge") }
            return value
        case UInt8(ascii: "U"):
            guard let value = cursor.readHex(count: 8) else { throw cursor.error("Ungültige \\U-Folge") }
            return value
        default:
            throw cursor.error("Ungültige Escape-Folge")
        }
    }

    // MARK: Leerraum

    private mutating func skipSpaces() {
        while cursor.current == UInt8(ascii: " ") || cursor.current == UInt8(ascii: "\t") { cursor.advance() }
    }

    private mutating func skipComment() {
        while let byte = cursor.current, byte != UInt8(ascii: "\n") { cursor.advance() }
    }

    private mutating func skipNewline() {
        if cursor.hasPrefix("\r\n") { cursor.advance(2) } else if cursor.current == UInt8(ascii: "\n") { cursor.advance() }
    }

    /// Leerraum, Zeilenumbrüche und Kommentare innerhalb eines Arrays.
    private mutating func skipArrayTrivia() throws(ConfigParseError) {
        while let byte = cursor.current {
            if Self.isWhitespaceOrNewline(byte) {
                cursor.advance()
            } else if byte == UInt8(ascii: "#") {
                skipComment()
            } else {
                return
            }
        }
        throw cursor.error("Array nicht abgeschlossen")
    }

    /// Nach einem Eintrag: nur Leerraum, Kommentar, Zeilenende oder Dateiende.
    private mutating func expectLineEnd() throws(ConfigParseError) {
        skipSpaces()
        if cursor.current == UInt8(ascii: "#") { skipComment() }
        switch cursor.current {
        case nil: return
        case UInt8(ascii: "\n"): cursor.advance()
        case UInt8(ascii: "\r") where cursor.peek(1) == UInt8(ascii: "\n"): cursor.advance(2)
        default: throw cursor.error("Zeilenende erwartet")
        }
    }

    // MARK: Zeichenklassen

    private static func isBareKeyByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"): true
        default: false
        }
    }

    private static func endsScalar(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "#"),
             UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"): true
        default: false
        }
    }

    /// Grobe Prüfung: Zahl (dezimal/hex/oktal/binär, `inf`, `nan`, mit optionalem Vorzeichen) oder Datum/Zeit. Der Wert
    /// wird nie gerechnet, es geht nur darum, Unsinn wie `nope` abzulehnen.
    private static func isNumberOrDateToken(_ token: ArraySlice<UInt8>) -> Bool {
        var rest = token
        if let sign = rest.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { rest = rest.dropFirst() }
        guard let first = rest.first else { return false }
        if ByteCursor.isDigit(first) { return rest.allSatisfy(isScalarByte) }
        return rest.elementsEqual("inf".utf8) || rest.elementsEqual("nan".utf8)
    }

    /// Zeichen, die in Zahlen (auch hex/oktal/binär) und Datum/Zeit vorkommen.
    private static func isScalarByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: ":"), UInt8(ascii: " "): true
        default: isBareKeyByte(byte)
        }
    }

    /// `JJJJ-MM-TT`.
    private static func isDate(_ token: ArraySlice<UInt8>) -> Bool {
        guard token.count == 10 else { return false }
        return token.enumerated().allSatisfy { offset, byte in
            offset == 4 || offset == 7 ? byte == UInt8(ascii: "-") : ByteCursor.isDigit(byte)
        }
    }

    private static func isWhitespaceOrNewline(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): true
        default: false
        }
    }

    /// Nach `\` in einem mehrzeiligen Basic-String: nur Leerraum bis zum Zeilenende.
    private static func isLineContinuation(_ cursor: ByteCursor) -> Bool {
        var offset = 0
        while let byte = cursor.peek(offset), byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") { offset += 1 }
        return cursor.peek(offset) == UInt8(ascii: "\n") || cursor.peek(offset) == UInt8(ascii: "\r")
    }
}

/// Veränderliche Tabelle während des Parsens; am Ende als `ConfigValue.object` ausgegeben.
private final class TOMLTable {
    enum Entry {
        case value(ConfigValue)
        case table(TOMLTable)
        case tables([TOMLTable])
    }

    private var entries: [(key: String, entry: Entry)] = []
    /// Position je Schlüssel – hält das Nachschlagen auch bei sehr vielen Schlüsseln schnell.
    private var positions: [String: Int] = [:]
    /// Durch `[kopf]` ausdrücklich definiert – ein zweiter Kopf ist ein Fehler.
    var isExplicit = false

    func entry(_ key: String) -> Entry? {
        positions[key].map { entries[$0].entry }
    }

    /// Setzt oder ersetzt den Eintrag (Reihenfolge des ersten Vorkommens bleibt).
    func set(_ key: String, _ entry: Entry) {
        if let index = positions[key] {
            entries[index].entry = entry
        } else {
            positions[key] = entries.count
            entries.append((key, entry))
        }
    }

    /// Hängt eine neue Tabelle an das Array von Tabellen unter `key` an und legt es bei freiem Schlüssel an. `nil`, wenn
    /// der Schlüssel anders belegt ist. Das Array wird in place erweitert: Eine lebende Kopie (`list + [table]`) ließe
    /// jeden `[[kopf]]` das ganze Array kopieren – quadratisch bei präparierten Dateien.
    func appendTable(to key: String) -> TOMLTable? {
        let table = TOMLTable()
        guard let index = positions[key] else {
            set(key, .tables([table]))
            return table
        }
        guard case .tables(var list) = entries[index].entry else { return nil }
        // Die Referenz im Eintrag freigeben, sonst kopiert `append` das Array, weil es zwei Besitzer hat.
        entries[index].entry = .tables([])
        list.append(table)
        entries[index].entry = .tables(list)
        return table
    }

    var value: ConfigValue {
        .object(ConfigObject(members: entries.map { ConfigObject.Member(key: $0.key, value: Self.value(of: $0.entry)) }))
    }

    private static func value(of entry: Entry) -> ConfigValue {
        switch entry {
        case .value(let value): value
        case .table(let table): table.value
        case .tables(let tables): .array(tables.map(\.value))
        }
    }
}
