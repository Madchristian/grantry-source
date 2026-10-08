/// JSON (strikt) bzw. JSONC (`allowsExtensions`: Kommentare, nachgestellte Kommas) in einen `ConfigValue`.
///
/// Werte, die `redaction` schwärzt, werden nur syntaktisch geprüft, nicht gesammelt (`ConfigValue.redacted`); Objekte
/// darunter behalten ihre Schlüssel. Dafür führt der Parser den Pfad des aktuellen Objekts mit (`nil` je Array-Ebene). Tiefe ist begrenzt (`maximumDepth`), damit präparierte Dateien den Stack nicht sprengen.
struct JSONConfigParser {
    /// Echte Konfigurationen verschachteln kaum über zehn Ebenen. Der Wert ist bewusst klein: Im Debug-Build kostet eine
    /// Ebene rund 3 KB Stack, auf Hintergrund-Threads (512 KB) kippt der Parser bei etwa 180 Ebenen.
    static let maximumDepth = 64

    private var cursor: ByteCursor
    private let allowsExtensions: Bool
    private let redaction: ConfigRedaction
    /// Schlüsselpfad des Werts, der gerade gelesen wird; höchstens `maximumDepth` Glieder.
    private var path: [String?] = []
    /// Container, deren Lage `layout` festhält (Stufe 2: Editor); leer beim Scan.
    private let recordedContainers: Set<[String]>
    /// Lage der Container unter `recordedContainers` – nur Byte-Positionen, nie Inhalte.
    private(set) var layout = JSONLayout()

    init(bytes: [UInt8], allowsExtensions: Bool, redaction: ConfigRedaction, recordedContainers: Set<[String]> = []) {
        cursor = ByteCursor(bytes: bytes)
        self.allowsExtensions = allowsExtensions
        self.redaction = redaction
        self.recordedContainers = recordedContainers
    }

    mutating func parseDocument() throws(ConfigParseError) -> ConfigValue {
        try skipTrivia()
        let value = try parseValue(depth: 0, redacted: false)
        try skipTrivia()
        guard cursor.isAtEnd else { throw cursor.error("Unerwartetes Zeichen nach dem Dokument") }
        return value
    }

    private mutating func parseValue(depth: Int, redacted: Bool) throws(ConfigParseError) -> ConfigValue {
        guard depth < Self.maximumDepth else { throw cursor.error("Zu tief verschachtelt") }
        guard let byte = cursor.current else { throw cursor.error("Unerwartetes Dateiende") }
        switch byte {
        case UInt8(ascii: "{"):
            return .object(try parseObject(depth: depth, redacted: redacted))
        case UInt8(ascii: "["):
            let elements = try parseArray(depth: depth, redacted: redacted)
            return redacted ? .redacted : .array(elements)
        case UInt8(ascii: "\""):
            let string = try scanString(collect: !redacted)
            return redacted ? .redacted : .string(string)
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return redacted ? .redacted : .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return redacted ? .redacted : .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return redacted ? .redacted : .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            let number = try scanNumber()
            return redacted ? .redacted : .number(number)
        default:
            throw cursor.error("Unerwartetes Zeichen")
        }
    }

    private mutating func parseObject(depth: Int, redacted: Bool) throws(ConfigParseError) -> ConfigObject {
        let recording = ContainerRecording(path: recordedPath(), open: cursor.index)
        var items: [JSONItemSpan] = []
        cursor.advance()
        var object = ConfigObject()
        try skipTrivia()
        if cursor.current == UInt8(ascii: "}") {
            record(recording, items: items)
            cursor.advance()
            return object
        }
        while true {
            guard cursor.current == UInt8(ascii: "\"") else { throw cursor.error("Schlüssel erwartet") }
            let start = cursor.index
            let key = try scanString(collect: true)
            try skipTrivia()
            guard cursor.current == UInt8(ascii: ":") else { throw cursor.error("„:“ erwartet") }
            cursor.advance()
            try skipTrivia()
            let isRedacted = redacted || redaction.redacts(key, under: path)
            let valueStart = cursor.index
            path.append(key)
            object.append(key, try parseValue(depth: depth + 1, redacted: isRedacted))
            path.removeLast()
            let end = cursor.index
            try skipTrivia()
            switch cursor.current {
            case UInt8(ascii: ","):
                if recording != nil { items.append(JSONItemSpan(start: start, valueStart: valueStart, end: end, comma: cursor.index)) }
                cursor.advance()
                try skipTrivia()
                if allowsExtensions, cursor.current == UInt8(ascii: "}") {
                    record(recording, items: items)
                    cursor.advance()
                    return object
                }
            case UInt8(ascii: "}"):
                if recording != nil { items.append(JSONItemSpan(start: start, valueStart: valueStart, end: end, comma: nil)) }
                record(recording, items: items)
                cursor.advance()
                return object
            default:
                throw cursor.error("„,“ oder „}“ erwartet")
            }
        }
    }

    private mutating func parseArray(depth: Int, redacted: Bool) throws(ConfigParseError) -> [ConfigValue] {
        let recording = ContainerRecording(path: recordedPath(), open: cursor.index)
        var items: [JSONItemSpan] = []
        cursor.advance()
        var elements: [ConfigValue] = []
        try skipTrivia()
        if cursor.current == UInt8(ascii: "]") {
            record(recording, items: items)
            cursor.advance()
            return elements
        }
        path.append(nil)
        defer { path.removeLast() }
        while true {
            let start = cursor.index
            elements.append(try parseValue(depth: depth + 1, redacted: redacted))
            let end = cursor.index
            try skipTrivia()
            switch cursor.current {
            case UInt8(ascii: ","):
                if recording != nil { items.append(JSONItemSpan(start: start, valueStart: start, end: end, comma: cursor.index)) }
                cursor.advance()
                try skipTrivia()
                if allowsExtensions, cursor.current == UInt8(ascii: "]") {
                    record(recording, items: items)
                    cursor.advance()
                    return elements
                }
            case UInt8(ascii: "]"):
                if recording != nil { items.append(JSONItemSpan(start: start, valueStart: start, end: end, comma: nil)) }
                record(recording, items: items)
                cursor.advance()
                return elements
            default:
                throw cursor.error("„,“ oder „]“ erwartet")
            }
        }
    }

    // MARK: Lage (Stufe 2)

    /// Ein Container, dessen Lage festgehalten wird: sein Pfad und die Position der öffnenden Klammer.
    private struct ContainerRecording {
        let path: [String]
        let open: Int

        init?(path: [String]?, open: Int) {
            guard let path else { return nil }
            self.path = path
            self.open = open
        }
    }

    /// Pfad des Containers, der gerade beginnt, wenn seine Lage gefragt ist; `nil` sonst und unter Array-Elementen.
    private func recordedPath() -> [String]? {
        guard !recordedContainers.isEmpty else { return nil }
        var keys: [String] = []
        keys.reserveCapacity(path.count)
        for component in path {
            guard let component else { return nil }
            keys.append(component)
        }
        return recordedContainers.contains(keys) ? keys : nil
    }

    /// Hält den Container fest; der Cursor steht auf der schließenden Klammer.
    private mutating func record(_ recording: ContainerRecording?, items: [JSONItemSpan]) {
        guard let recording else { return }
        layout.containers[recording.path, default: []]
            .append(JSONContainerSpan(open: recording.open, close: cursor.index, items: items))
    }

    /// Liest einen String ab dem öffnenden `"`; mit `collect == false` nur prüfen (Ergebnis leer).
    private mutating func scanString(collect: Bool) throws(ConfigParseError) -> String {
        cursor.advance()
        var buffer: [UInt8] = []
        while true {
            guard let byte = cursor.current else { throw cursor.error("String nicht abgeschlossen") }
            // Vor dem Vorrücken prüfen: Sonst würde ein roher Zeilenumbruch die Fehlerzeile um eins erhöhen.
            guard byte >= 0x20 else { throw cursor.error("Steuerzeichen im String") }
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

    /// Escape nach `\`; liefert den Unicode-Skalar (Surrogatpaare zusammengesetzt, einzelne → U+FFFD).
    private mutating func scanEscape() throws(ConfigParseError) -> UInt32 {
        guard let byte = cursor.current else { throw cursor.error("String nicht abgeschlossen") }
        cursor.advance()
        switch byte {
        case UInt8(ascii: "\""): return 0x22
        case UInt8(ascii: "\\"): return 0x5C
        case UInt8(ascii: "/"): return 0x2F
        case UInt8(ascii: "b"): return 0x08
        case UInt8(ascii: "f"): return 0x0C
        case UInt8(ascii: "n"): return 0x0A
        case UInt8(ascii: "r"): return 0x0D
        case UInt8(ascii: "t"): return 0x09
        case UInt8(ascii: "u"):
            guard let high = cursor.readHex(count: 4) else { throw cursor.error("Ungültige \\u-Folge") }
            guard (0xD800...0xDBFF).contains(high) else { return high }
            guard cursor.hasPrefix("\\u") else { return 0xFFFD }
            let afterHigh = cursor
            cursor.advance(2)
            guard let low = cursor.readHex(count: 4) else { throw cursor.error("Ungültige \\u-Folge") }
            guard (0xDC00...0xDFFF).contains(low) else {
                // Kein Paar: das hohe Surrogat wird zu U+FFFD, das zweite Escape bleibt für den nächsten Durchlauf stehen.
                cursor = afterHigh
                return 0xFFFD
            }
            return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
        default:
            throw cursor.error("Ungültige Escape-Folge")
        }
    }

    /// Zahl nach RFC 8259 (`-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`) als Quelltext.
    private mutating func scanNumber() throws(ConfigParseError) -> String {
        let start = cursor.index
        if cursor.current == UInt8(ascii: "-") { cursor.advance() }
        if cursor.current == UInt8(ascii: "0") {
            cursor.advance()
        } else {
            guard ByteCursor.isDigit(cursor.current) else { throw cursor.error("Ungültige Zahl") }
            while ByteCursor.isDigit(cursor.current) { cursor.advance() }
        }
        if cursor.current == UInt8(ascii: ".") {
            cursor.advance()
            guard ByteCursor.isDigit(cursor.current) else { throw cursor.error("Ungültige Zahl") }
            while ByteCursor.isDigit(cursor.current) { cursor.advance() }
        }
        if cursor.current == UInt8(ascii: "e") || cursor.current == UInt8(ascii: "E") {
            cursor.advance()
            if cursor.current == UInt8(ascii: "+") || cursor.current == UInt8(ascii: "-") { cursor.advance() }
            guard ByteCursor.isDigit(cursor.current) else { throw cursor.error("Ungültige Zahl") }
            while ByteCursor.isDigit(cursor.current) { cursor.advance() }
        }
        if ByteCursor.isDigit(cursor.current) { throw cursor.error("Ungültige Zahl") }
        return String(decoding: cursor.bytes[start..<cursor.index], as: UTF8.self)
    }

    private mutating func expectLiteral(_ literal: String) throws(ConfigParseError) {
        guard cursor.hasPrefix(literal) else { throw cursor.error("Unerwartetes Zeichen") }
        cursor.advance(literal.utf8.count)
    }

    /// Leerraum und – bei JSONC – Kommentare.
    private mutating func skipTrivia() throws(ConfigParseError) {
        while let byte = cursor.current {
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                cursor.advance()
            case UInt8(ascii: "/") where allowsExtensions && cursor.peek(1) == UInt8(ascii: "/"):
                while let next = cursor.current, next != UInt8(ascii: "\n") { cursor.advance() }
            case UInt8(ascii: "/") where allowsExtensions && cursor.peek(1) == UInt8(ascii: "*"):
                cursor.advance(2)
                while !cursor.hasPrefix("*/") {
                    guard !cursor.isAtEnd else { throw cursor.error("Kommentar nicht abgeschlossen") }
                    cursor.advance()
                }
                cursor.advance(2)
            default:
                return
            }
        }
    }
}
