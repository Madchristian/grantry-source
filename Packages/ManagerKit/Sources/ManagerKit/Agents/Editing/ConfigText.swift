import Foundation

/// Eine Textänderung an Bytes: `range` wird durch `replacement` ersetzt (leerer Bereich = Einfügen).
struct ByteEdit: Hashable, Sendable {
    let range: Range<Int>
    let replacement: [UInt8]

    static func delete(_ range: Range<Int>) -> ByteEdit {
        ByteEdit(range: range, replacement: [])
    }

    static func insert(_ text: [UInt8], at position: Int) -> ByteEdit {
        ByteEdit(range: position..<position, replacement: text)
    }
}

extension Array where Element == UInt8 {
    /// Wendet nicht überlappende Änderungen an; die Reihenfolge im Array ist beliebig – außer bei gleicher Lage: Dann
    /// steht die frühere im Array auch früher im Text (stabil, Index als Tiebreaker; etwa zwei Einfügungen am
    /// Dateiende). Überlappen sich zwei, ist das ein Programmfehler.
    func applying(_ edits: [ByteEdit]) -> [UInt8] {
        let sorted = edits.indices.sorted { first, second in
            (edits[first].range.lowerBound, edits[first].range.upperBound, first)
                > (edits[second].range.lowerBound, edits[second].range.upperBound, second)
        }.map { edits[$0] }
        var result = self
        var limit = count
        for edit in sorted {
            precondition(edit.range.upperBound <= limit, "Überlappende Textänderungen")
            result.replaceSubrange(edit.range, with: edit.replacement)
            limit = edit.range.lowerBound
        }
        return result
    }
}

/// Zeilen, Leerraum und Schreibweisen für textuelle Änderungen – gemeinsam für JSON und TOML.
enum ConfigText {
    static let newlineByte = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }

    /// Zeilenende der Datei: CRLF, wenn das erste Zeilenende CRLF ist, sonst LF.
    static func newline(of bytes: [UInt8]) -> [UInt8] {
        guard let first = bytes.firstIndex(of: newlineByte) else { return [newlineByte] }
        return first > 0 && bytes[first - 1] == carriageReturn ? [carriageReturn, newlineByte] : [newlineByte]
    }

    /// Anfang der Zeile, in der `index` liegt.
    static func lineStart(of index: Int, in bytes: [UInt8]) -> Int {
        var position = index
        while position > 0, bytes[position - 1] != newlineByte { position -= 1 }
        return position
    }

    /// Hinter Leerzeichen und Tabs ab `index`.
    static func skippingSpaces(from index: Int, in bytes: [UInt8]) -> Int {
        var position = index
        while position < bytes.count, isSpace(bytes[position]) { position += 1 }
        return position
    }

    /// Länge des Zeilenendes ab `index` (2 für CRLF, 1 für LF, 0 am Dateiende); `nil`, wenn dort kein Zeilenende steht.
    static func lineBreakLength(at index: Int, in bytes: [UInt8]) -> Int? {
        guard index < bytes.count else { return 0 }
        if bytes[index] == newlineByte { return 1 }
        if bytes[index] == carriageReturn, index + 1 < bytes.count, bytes[index + 1] == newlineByte { return 2 }
        return nil
    }

    /// Einrückung vor `index`, wenn davor in der Zeile nur Leerraum steht; sonst `nil`.
    static func indentation(before index: Int, in bytes: [UInt8]) -> [UInt8]? {
        let start = lineStart(of: index, in: bytes)
        let prefix = bytes[start..<index]
        return prefix.allSatisfy(isSpace) ? Array(prefix) : nil
    }

    /// Einrückungsstufe der Datei: die Einrückung der ersten eingerückten Zeile (in üblich formatierten Dateien die erste
    /// Ebene); zwei Leerzeichen, wenn keine Zeile eingerückt ist.
    static func indentationUnit(of bytes: [UInt8]) -> [UInt8] {
        var start = 0
        while start < bytes.count {
            let end = skippingSpaces(from: start, in: bytes)
            if end > start, lineBreakLength(at: end, in: bytes) == nil { return Array(bytes[start..<end]) }
            guard let next = bytes[end...].firstIndex(of: newlineByte) else { break }
            start = next + 1
        }
        return Array("  ".utf8)
    }

    /// Ende der Leerzeilen ab `index` (das selbst ein Zeilenanfang ist): hinter jeder Zeile, die nur Leerraum enthält.
    static func skippingBlankLines(from index: Int, in bytes: [UInt8]) -> Int {
        var position = index
        while position < bytes.count {
            let afterSpaces = skippingSpaces(from: position, in: bytes)
            guard let length = lineBreakLength(at: afterSpaces, in: bytes) else { break }
            position = afterSpaces + length
            if length == 0 { break }
        }
        return position
    }

    /// Anfang der Leerzeilen direkt vor `index` (einem Zeilenanfang).
    static func precedingBlankLinesStart(before index: Int, in bytes: [UInt8]) -> Int {
        var position = index
        while position > 0 {
            let previous = lineStart(of: position - 1, in: bytes)
            guard bytes[previous..<position].allSatisfy({ isSpace($0) || $0 == newlineByte || $0 == carriageReturn }) else { break }
            position = previous
        }
        return position
    }

    /// `true`, wenn `bytes` mit einem Zeilenende schließt (oder leer ist).
    static func endsWithNewline(_ bytes: [UInt8]) -> Bool {
        bytes.last.map { $0 == newlineByte } ?? true
    }

    // MARK: Schreibweisen

    /// JSON-String samt Anführungszeichen; `"`, `\` und Steuerzeichen maskiert.
    static func jsonString(_ text: String) -> [UInt8] {
        var result: [UInt8] = [UInt8(ascii: "\"")]
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += Array(#"\""#.utf8)
            case "\\": result += Array(#"\\"#.utf8)
            case "\n": result += Array(#"\n"#.utf8)
            case "\r": result += Array(#"\r"#.utf8)
            case "\t": result += Array(#"\t"#.utf8)
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += Array(String(format: "\\u%04x", scalar.value).utf8)
            default:
                result += Array(String(scalar).utf8)
            }
        }
        result.append(UInt8(ascii: "\""))
        return result
    }

    /// TOML-Schlüssel: nackt, wenn er nur aus `A-Za-z0-9_-` besteht, sonst als Basic-String.
    static func tomlKey(_ key: String) -> [UInt8] {
        let isBare = !key.isEmpty && key.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"): true
            default: false
            }
        }
        return isBare ? Array(key.utf8) : jsonString(key)
    }

    /// Punktierter TOML-Schlüsselpfad (`a."b c".d`).
    static func tomlKeyPath(_ keys: [String]) -> [UInt8] {
        Array(keys.map(tomlKey).joined(separator: [UInt8(ascii: ".")]))
    }

    static func bool(_ value: Bool) -> [UInt8] {
        Array((value ? "true" : "false").utf8)
    }
}
