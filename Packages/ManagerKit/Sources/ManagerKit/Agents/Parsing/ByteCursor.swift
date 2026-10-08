/// Lesekopf über UTF-8-Bytes, gemeinsam für die Konfigurationsparser. Fehler tragen die Zeilennummer der Position.
struct ByteCursor {
    let bytes: [UInt8]
    private(set) var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { index >= bytes.count }
    var current: UInt8? { peek(0) }

    func peek(_ offset: Int) -> UInt8? {
        let position = index + offset
        return position < bytes.count ? bytes[position] : nil
    }

    mutating func advance(_ count: Int = 1) {
        index = min(index + count, bytes.count)
    }

    /// `true`, wenn die Bytes ab der Position mit `text` beginnen (ohne Zwischenpuffer – wird je Zeichen aufgerufen).
    func hasPrefix(_ text: String) -> Bool {
        var position = index
        for byte in text.utf8 {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
        }
        return true
    }

    /// Fehler an der aktuellen Position (Zeilen ab 1).
    func error(_ reason: String) -> ConfigParseError {
        let end = min(index, bytes.count)
        return ConfigParseError(line: 1 + bytes[..<end].reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }, reason: reason)
    }

    static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }

    static func isDigit(_ byte: UInt8?) -> Bool {
        byte.map { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } == true
    }

    /// Liest `count` Hex-Ziffern; `nil`, wenn eine fehlt.
    mutating func readHex(count: Int) -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<count {
            guard let byte = current, let digit = Self.hexValue(byte) else { return nil }
            value = value << 4 | digit
            advance()
        }
        return value
    }
}

extension Array where Element == UInt8 {
    /// Hängt das UTF-8 eines Unicode-Skalars an; ungültige Werte werden zu U+FFFD.
    mutating func appendScalar(_ value: UInt32) {
        UTF8.encode(Unicode.Scalar(value) ?? "\u{FFFD}") { append($0) }
    }
}
