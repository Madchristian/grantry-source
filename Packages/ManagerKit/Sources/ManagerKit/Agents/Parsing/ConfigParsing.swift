import Foundation

/// Format einer Konfigurationsdatei.
public enum ConfigSyntax: String, Hashable, Sendable, Codable {
    /// Strenges JSON (RFC 8259).
    case json
    /// JSON mit `//`- und `/* */`-Kommentaren und nachgestellten Kommas (VS Code, Zed).
    case jsonc
    /// TOML-1.0-Teilmenge (Codex).
    case toml
}

/// Syntaxfehler mit Zeilennummer – erscheint als Einschränkung der Quelle, nie mit Dateiinhalt.
struct ConfigParseError: Error, Hashable, Sendable, CustomStringConvertible {
    let line: Int
    let reason: String

    init(line: Int, reason: String) {
        self.line = line
        self.reason = reason
    }

    var description: String { "Zeile \(line): \(reason)" }
}

/// Einstieg der Konfigurationsparser.
enum ConfigParsing {
    static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Trennt eine UTF-8-BOM ab – die einzige Stelle dafür: Parser sehen den Inhalt ohne sie, der Editor setzt sie
    /// danach wieder davor.
    static func splittingByteOrderMark(_ data: Data) -> (byteOrderMark: [UInt8], body: [UInt8]) {
        let bytes = [UInt8](data)
        guard bytes.starts(with: byteOrderMark) else { return ([], bytes) }
        return (byteOrderMark, Array(bytes.dropFirst(byteOrderMark.count)))
    }

    /// `true`, wenn `data` nach einer optionalen UTF-8-BOM nur Leerraum (Leerzeichen, Tab, Zeilenende) enthält – eine
    /// solche Datei ist keine Konfiguration, kein Syntaxfehler.
    static func isBlank(_ data: Data) -> Bool {
        splittingByteOrderMark(data).body.allSatisfy(isWhitespace)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// - Parameter redaction: Welche Werte übersprungen werden (`ConfigValue.redacted`).
    static func parse(
        _ data: Data, syntax: ConfigSyntax, redaction: ConfigRedaction
    ) throws(ConfigParseError) -> ConfigValue {
        try parse(splittingByteOrderMark(data).body, syntax: syntax, redaction: redaction, recording: nil).tree
    }

    /// Format-Weiche aller Parser: `bytes` ohne BOM. Mit `containers` (Editor, Stufe 2) hält die Lage bei JSON diese
    /// Container fest, bei TOML alle Anweisungen; ohne (Scan) bleibt sie leer und wird gar nicht erst gebaut.
    static func parse(
        _ bytes: [UInt8], syntax: ConfigSyntax, redaction: ConfigRedaction, recording containers: Set<[String]>?
    ) throws(ConfigParseError) -> (tree: ConfigValue, layout: ConfigDocument.Layout) {
        switch syntax {
        case .json, .jsonc:
            var parser = JSONConfigParser(bytes: bytes, allowsExtensions: syntax == .jsonc, redaction: redaction,
                                          recordedContainers: containers ?? [])
            return (try parser.parseDocument(), .json(parser.layout))
        case .toml:
            var parser = TOMLConfigParser(bytes: bytes, redaction: redaction, recordsLayout: containers != nil)
            return (try parser.parseDocument(), .toml(parser.layout))
        }
    }
}
