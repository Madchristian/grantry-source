/// Textuelle Änderungen an TOML (Stufe 2) auf Grundlage der Anweisungen aus dem Parser (`TOMLLayout`). Ein Server
/// `[mcp_servers.x]` besteht aus allen Anweisungen, deren Pfad mit `mcp_servers.x` beginnt: seinen Tabellen (samt
/// Untertabellen wie `[mcp_servers.x.env]`, auch verstreut in der Datei) und punktierten Schlüsseln bzw. einer
/// Inline-Tabelle in anderen Tabellen (`x.command = …`, `x = { … }`). Alles andere bleibt byte-genau erhalten.
///
/// Steht der Server innerhalb eines Werts (`mcp_servers = { x = { … } }`) oder in einem Array von Tabellen, lässt er
/// sich nicht gezielt ändern (`unsupportedLayout`). Rein, ohne Dateizugriff.
enum TOMLConfigEditor {
    /// Entfernt alle Anweisungen des Eintrags unter `path`.
    ///
    /// Eine Tabelle reicht vom Kopf bis zum Ende ihrer letzten Anweisung; Kommentare dazwischen gehören dazu, Kommentare
    /// danach gehören zur nächsten Tabelle und bleiben. Leerzeilen hinter einer entfernten Tabelle fallen mit weg; endet
    /// sie die Datei, auch die Leerzeilen davor.
    static func removeEntry(at path: [String], of document: ConfigDocument) throws(AgentConfigEditError) -> [ByteEdit] {
        let statements = try statements(of: document)
        try ensureEditable(path, in: statements)
        var tables: [Range<Int>] = []
        var lines: [Range<Int>] = []
        for part in parts(ofEntryAt: path, in: statements) {
            if part.isBlock { tables.append(part.range) } else { lines.append(part.range) }
        }
        guard !tables.isEmpty || !lines.isEmpty else { throw .entryChanged }
        // Leerzeilen fallen nur mit ganzen Tabellen weg; danach erneut zusammenfassen, weil erst sie Bereiche zu
        // Nachbarn machen.
        let blocks = merged(tables).map { withBlankLines($0, in: document.bytes) }
        return merged(blocks + lines).map(ByteEdit.delete)
    }

    /// Setzt den Bool `key` des Eintrags unter `path`: ersetzt einen vorhandenen Wert oder fügt `key = wert` hinzu –
    /// in die Inline-Tabelle, unter den Kopf der Tabelle oder hinter den letzten punktierten Schlüssel des Eintrags.
    static func setBool(
        _ value: Bool, key: String, ofEntryAt path: [String], of document: ConfigDocument
    ) throws(AgentConfigEditError) -> [ByteEdit] {
        let statements = try statements(of: document)
        try ensureEditable(path, in: statements)
        let bytes = document.bytes
        let target = path + [key]
        if let existing = statements.first(where: { $0.kind == .keyValue && $0.path == target }), let range = existing.valueRange {
            return [ByteEdit(range: range, replacement: ConfigText.bool(value))]
        }
        // Vorhanden, aber nicht als eigene Anweisung (etwa innerhalb einer Inline-Tabelle `env = { … }`).
        guard document.tree.value(at: target) == nil else { throw .unsupportedLayout }
        let assignment = ConfigText.tomlKey(key) + Array(" = ".utf8) + ConfigText.bool(value)
        if let inline = statements.first(where: { $0.kind == .keyValue && $0.path == path }), let range = inline.valueRange {
            return [try inlineInsertion(of: assignment, intoInlineTableAt: range, in: bytes)]
        }
        if let headerIndex = statements.firstIndex(where: { $0.kind == .table && $0.path == path }) {
            // Einrückung wie die erste Anweisung der Tabelle, sonst wie ihr Kopf.
            let header = statements[headerIndex]
            let next = statements.indices.contains(headerIndex + 1) && statements[headerIndex + 1].kind == .keyValue
                ? statements[headerIndex + 1] : header
            return [lineInsertion(of: indentation(of: next, in: bytes) + assignment, after: header.range, in: bytes)]
        }
        if let last = statements.last(where: { $0.kind == .keyValue && $0.path.starts(with: path) && path.starts(with: $0.tablePath) }) {
            let relative = Array(path.dropFirst(last.tablePath.count)) + [key]
            let line = indentation(of: last, in: bytes) + ConfigText.tomlKeyPath(relative) + Array(" = ".utf8) + ConfigText.bool(value)
            return [lineInsertion(of: line, after: last.range, in: bytes)]
        }
        throw .unsupportedLayout
    }

    /// Fügt den Eintrag unter `path` aus `backup` (derselben Datei vor der Änderung) wieder in `document` ein: seine
    /// Tabellen am Dateiende (durch Leerzeilen getrennt), seine punktierten Schlüssel bzw. die Inline-Tabelle hinter die
    /// letzte Anweisung derselben Tabelle in `document` (vor dem ersten Kopf, wenn sie auf oberster Ebene standen).
    static func reinsertEntry(at path: [String], from backup: ConfigDocument, into document: ConfigDocument) throws(AgentConfigEditError) -> [ByteEdit] {
        let source = try statements(of: backup)
        let target = try statements(of: document)
        try ensureEditable(path, in: target)
        let newline = ConfigText.newline(of: document.bytes)
        var blocks: [[UInt8]] = []
        // Zeilen je Einfügestelle in der Reihenfolge der Sicherung.
        var lines: [(position: Int, text: [UInt8])] = []
        for part in parts(ofEntryAt: path, in: source) {
            let text = terminated(Array(backup.bytes[part.range]), newline: newline)
            guard !part.isBlock else {
                blocks.append(text)
                continue
            }
            let position = try insertionPoint(forTable: part.statement.tablePath, in: target, of: document)
            if let existing = lines.firstIndex(where: { $0.position == position }) {
                lines[existing].text += text
            } else {
                lines.append((position, text))
            }
        }
        var edits = lines.map { ByteEdit.insert($0.text, at: $0.position) }
        if !blocks.isEmpty {
            let bytes = document.bytes
            edits.append(.insert(blockSeparator(before: bytes.count, in: bytes, newline: newline)
                + Array(blocks.joined(separator: newline)), at: bytes.count))
        }
        guard !edits.isEmpty else { throw .entryChanged }
        return edits
    }

    /// Quelltext des Eintrags unter `path` in Dateireihenfolge – je Tabelle der ganze Block, je punktiertem Schlüssel
    /// bzw. Inline-Tabelle die Anweisung, jeweils ohne Leerraum am Ende. Zum byte-genauen Vergleich mit der Sicherung.
    static func entryText(at path: [String], of document: ConfigDocument) throws(AgentConfigEditError) -> [[UInt8]] {
        let statements = try statements(of: document)
        try ensureEditable(path, in: statements)
        return parts(ofEntryAt: path, in: statements).map { part in
            var text = document.bytes[part.range]
            while let last = text.last, ConfigText.isSpace(last) || last == ConfigText.newlineByte || last == UInt8(ascii: "\r") {
                text.removeLast()
            }
            return Array(text)
        }
    }

    // MARK: Lage

    /// Die Teile des Eintrags unter `path`: Tabellen (`isBlock`, je Kopf vom Kopf bis zu seiner letzten Anweisung –
    /// jede Untertabelle ist ein eigener Block, auch wenn sie direkt folgt) und punktierte Schlüssel bzw. Inline-Tabellen
    /// in anderen Tabellen. Anweisungen innerhalb einer Tabelle des Eintrags gehören zu deren Block.
    private static func parts(
        ofEntryAt path: [String], in statements: [TOMLStatement]
    ) -> [(statement: TOMLStatement, range: Range<Int>, isBlock: Bool)] {
        statements.indices.compactMap { index in
            let statement = statements[index]
            guard statement.path.starts(with: path) else { return nil }
            switch statement.kind {
            case .table, .arrayTable: return (statement, blockRange(ofHeaderAt: index, in: statements), true)
            case .keyValue where !statement.tablePath.starts(with: path): return (statement, statement.range, false)
            case .keyValue: return nil
            }
        }
    }

    private static func statements(of document: ConfigDocument) throws(AgentConfigEditError) -> [TOMLStatement] {
        guard case .toml(let layout) = document.layout else { throw .unsupportedLayout }
        return layout.statements
    }

    /// Lehnt Einträge ab, die in einem Wert stehen (eine Anweisung, deren Pfad echt vor `path` endet) oder in einem
    /// Array von Tabellen (ein `[[kopf]]` mit `path` als Fortsetzung).
    private static func ensureEditable(_ path: [String], in statements: [TOMLStatement]) throws(AgentConfigEditError) {
        let inValue = statements.contains { $0.kind == .keyValue && $0.path.count < path.count && path.starts(with: $0.path) }
        if inValue || isInArrayOfTables(path, statements) { throw .unsupportedLayout }
    }

    /// Ob `path` unter einem `[[kopf]]` liegt – auch, wenn der Baum ihn dort nicht als Objekt zeigt: `[mcp_servers.x]`
    /// hinter `[[mcp_servers]]` gehört zum letzten Element des Arrays, Pfade kennen keine Array-Ebenen.
    static func isInArrayOfTables(_ path: [String], of document: ConfigDocument) throws(AgentConfigEditError) -> Bool {
        isInArrayOfTables(path, try statements(of: document))
    }

    private static func isInArrayOfTables(_ path: [String], _ statements: [TOMLStatement]) -> Bool {
        statements.contains { $0.kind == .arrayTable && $0.path.count <= path.count && path.starts(with: $0.path) }
    }

    /// Kopf an `index` bis zum Ende seiner letzten Anweisung (vor dem nächsten Kopf).
    private static func blockRange(ofHeaderAt index: Int, in statements: [TOMLStatement]) -> Range<Int> {
        var end = statements[index].range.upperBound
        var next = index + 1
        while next < statements.count, statements[next].kind == .keyValue {
            end = statements[next].range.upperBound
            next += 1
        }
        return statements[index].range.lowerBound..<end
    }

    /// Wo eine Anweisung der Tabelle `tablePath` eingefügt wird: hinter ihrer letzten Anweisung bzw. hinter ihrem Kopf;
    /// für die oberste Ebene vor dem ersten Kopf (oder am Ende einer Datei ohne Kopf).
    private static func insertionPoint(
        forTable tablePath: [String], in statements: [TOMLStatement], of document: ConfigDocument
    ) throws(AgentConfigEditError) -> Int {
        if tablePath.isEmpty {
            return statements.first { $0.kind != .keyValue }?.range.lowerBound ?? document.bytes.count
        }
        guard let header = statements.firstIndex(where: { $0.kind == .table && $0.path == tablePath }) else {
            throw .unsupportedLayout
        }
        let end = blockRange(ofHeaderAt: header, in: statements).upperBound
        // Endet die Tabelle ohne Zeilenende (Dateiende), passt keine weitere Zeile dahinter.
        guard end == 0 || document.bytes[end - 1] == ConfigText.newlineByte else { throw .unsupportedLayout }
        return end
    }

    // MARK: Text

    /// Fasst überlappende oder aneinanderstoßende Bereiche zusammen.
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// `range` samt folgender Leerzeilen; reicht das bis ans Dateiende, auch samt Leerzeilen davor.
    private static func withBlankLines(_ range: Range<Int>, in bytes: [UInt8]) -> Range<Int> {
        let end = ConfigText.skippingBlankLines(from: range.upperBound, in: bytes)
        let start = end == bytes.count ? ConfigText.precedingBlankLinesStart(before: range.lowerBound, in: bytes) : range.lowerBound
        return start..<end
    }

    /// Fügt `line` als eigene Zeile hinter `range` (einer Anweisung samt Zeilenende) ein.
    private static func lineInsertion(of line: [UInt8], after range: Range<Int>, in bytes: [UInt8]) -> ByteEdit {
        let newline = ConfigText.newline(of: bytes)
        let endsLine = range.upperBound > 0 && bytes[range.upperBound - 1] == ConfigText.newlineByte
        return .insert(endsLine ? line + newline : newline + line, at: range.upperBound)
    }

    /// `, key = wert` vor die schließende Klammer der Inline-Tabelle `range` (bzw. ` key = wert ` in eine leere).
    private static func inlineInsertion(of assignment: [UInt8], intoInlineTableAt range: Range<Int>, in bytes: [UInt8]) throws(AgentConfigEditError) -> ByteEdit {
        guard range.count >= 2, bytes[range.lowerBound] == UInt8(ascii: "{"), bytes[range.upperBound - 1] == UInt8(ascii: "}") else {
            throw .unsupportedLayout
        }
        var last = range.upperBound - 2
        while last > range.lowerBound, ConfigText.isSpace(bytes[last]) { last -= 1 }
        if last == range.lowerBound {
            return ByteEdit(range: range.lowerBound + 1..<range.upperBound - 1,
                            replacement: [UInt8(ascii: " ")] + assignment + [UInt8(ascii: " ")])
        }
        return .insert(Array(", ".utf8) + assignment, at: last + 1)
    }

    /// Was vor einem neuen Block am Dateiende (`end`) steht: eine Leerzeile als Abstand – keine, wenn die Datei leer ist
    /// oder schon mit einer Leerzeile endet (nur Leerraum zählt als leer).
    private static func blockSeparator(before end: Int, in bytes: [UInt8], newline: [UInt8]) -> [UInt8] {
        guard ConfigText.endsWithNewline(bytes) else { return newline + newline }
        let endsBlank = ConfigText.precedingBlankLinesStart(before: end, in: bytes) < end
        return bytes.isEmpty || endsBlank ? [] : newline
    }

    /// Einrückung der Zeile, in der `statement` beginnt.
    private static func indentation(of statement: TOMLStatement, in bytes: [UInt8]) -> [UInt8] {
        ConfigText.indentation(before: ConfigText.skippingSpaces(from: statement.range.lowerBound, in: bytes), in: bytes) ?? []
    }

    /// `text` mit Zeilenende.
    private static func terminated(_ text: [UInt8], newline: [UInt8]) -> [UInt8] {
        ConfigText.endsWithNewline(text) ? text : text + newline
    }
}
