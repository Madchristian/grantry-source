/// Textuelle Änderungen an JSON/JSONC (Stufe 2): Ein Mitglied bzw. Element wird samt seinem Komma entfernt, eingefügt
/// oder sein Wert ersetzt – alle übrigen Bytes (Formatierung, Kommentare, Reihenfolge) bleiben unverändert.
///
/// Grundlage ist die Lage der Container aus dem Parser (`JSONLayout`); welche Elemente welche Schlüssel tragen, sagt der
/// Baum (`ConfigObject.members` in derselben Reihenfolge). Rein, ohne Dateizugriff. Jede Funktion liefert die
/// Änderungen, angewendet und nachgeprüft wird im `AgentConfigEditor`.
enum JSONConfigEditor {
    /// Entfernt das Mitglied `key` des Objekts unter `path` (genau ein Vorkommen, sonst `unsupportedLayout`).
    static func removeMember(_ key: String, inObjectAt path: [String], of document: ConfigDocument) throws(AgentConfigEditError) -> [ByteEdit] {
        let container = try container(at: path, of: document)
        let index = try memberIndex(key, in: container, at: path, of: document)
        return removal(of: index, in: container, of: document)
    }

    /// Ersetzt den Wert des Mitglieds `key` durch `value` (Quelltext) oder fügt `"key": value` am Ende des Objekts ein.
    static func setMember(
        _ key: String, to value: [UInt8], inObjectAt path: [String], of document: ConfigDocument
    ) throws(AgentConfigEditError) -> [ByteEdit] {
        let container = try container(at: path, of: document)
        guard document.tree.value(at: path)?.object?[key] != nil else {
            return [insertion(of: ConfigText.jsonString(key) + Array(": ".utf8) + value, into: container, of: document)]
        }
        let item = container.items[try memberIndex(key, in: container, at: path, of: document)]
        return [ByteEdit(range: item.valueStart..<item.end, replacement: value)]
    }

    /// Fügt `text` (ein vollständiges Mitglied `"name": …` bzw. ein Element) am Ende des Containers unter `path` ein.
    static func insert(_ text: [UInt8], intoContainerAt path: [String], of document: ConfigDocument) throws(AgentConfigEditError) -> [ByteEdit] {
        [insertion(of: text, into: try container(at: path, of: document), of: document)]
    }

    /// Entfernt das Element an `index` des Arrays unter `path`.
    static func removeElement(at index: Int, fromArrayAt path: [String], of document: ConfigDocument) throws(AgentConfigEditError) -> [ByteEdit] {
        let container = try container(at: path, of: document)
        guard container.items.indices.contains(index) else { throw .unsupportedLayout }
        return removal(of: index, in: container, of: document)
    }

    /// Quelltext des Mitglieds `key` (ab dem Schlüssel bis zum Ende des Werts) – zum Wiedereinfügen aus der Sicherung.
    static func memberText(_ key: String, inObjectAt path: [String], of document: ConfigDocument) throws(AgentConfigEditError) -> [UInt8] {
        let container = try container(at: path, of: document)
        let item = container.items[try memberIndex(key, in: container, at: path, of: document)]
        return Array(document.bytes[item.start..<item.end])
    }

    // MARK: Lage

    /// Genau ein Container unter `path`; fehlt er oder kommt sein Schlüssel doppelt vor: `unsupportedLayout`.
    private static func container(at path: [String], of document: ConfigDocument) throws(AgentConfigEditError) -> JSONContainerSpan {
        guard case .json(let layout) = document.layout, let spans = layout.containers[path], spans.count == 1 else {
            throw .unsupportedLayout
        }
        return spans[0]
    }

    /// Position des einzigen Mitglieds `key`; die Elemente des Containers entsprechen `ConfigObject.members`.
    private static func memberIndex(
        _ key: String, in container: JSONContainerSpan, at path: [String], of document: ConfigDocument
    ) throws(AgentConfigEditError) -> Int {
        guard let members = document.tree.value(at: path)?.object?.members, members.count == container.items.count else {
            throw .unsupportedLayout
        }
        let matches = members.indices.filter { members[$0].key == key }
        guard matches.count == 1 else { throw .unsupportedLayout }
        return matches[0]
    }

    // MARK: Entfernen

    /// Entfernt Element `index` samt Komma. Steht es allein in seinen Zeilen, verschwinden die Zeilen ganz (mit
    /// Einrückung und einem Zeilenkommentar dahinter); Kommentare in eigenen Zeilen davor oder danach bleiben. Hat das
    /// letzte Element kein eigenes Komma, fällt das Komma des vorigen weg – sonst bliebe ein nachgestelltes Komma, das
    /// strenges JSON nicht erlaubt.
    private static func removal(of index: Int, in container: JSONContainerSpan, of document: ConfigDocument) -> [ByteEdit] {
        let bytes = document.bytes
        let item = container.items[index]
        var edits: [ByteEdit] = []
        var start = item.start
        var end = item.comma.map { $0 + 1 } ?? item.end
        if item.comma == nil, index > 0, let previousComma = container.items[index - 1].comma {
            edits.append(.delete(previousComma..<previousComma + 1))
        }
        let afterSpaces = ConfigText.skippingSpaces(from: end, in: bytes)
        var afterComment = afterSpaces
        if document.syntax == .jsonc, bytes[afterSpaces...].starts(with: [UInt8(ascii: "/"), UInt8(ascii: "/")]) {
            while ConfigText.lineBreakLength(at: afterComment, in: bytes) == nil { afterComment += 1 }
        }
        if let lineBreak = ConfigText.lineBreakLength(at: afterComment, in: bytes),
           ConfigText.indentation(before: start, in: bytes) != nil {
            // Allein in seinen Zeilen: ganze Zeilen entfernen.
            start = ConfigText.lineStart(of: start, in: bytes)
            end = afterComment + lineBreak
        } else if item.comma != nil, ConfigText.lineBreakLength(at: afterSpaces, in: bytes) == nil {
            // Dahinter folgt in derselben Zeile das nächste Element: Leerraum bis dorthin mit entfernen.
            end = afterSpaces
        } else {
            // Letztes Element des Containers oder der Zeile: Leerraum davor mit entfernen.
            while start > 0, ConfigText.isSpace(bytes[start - 1]) { start -= 1 }
        }
        edits.append(.delete(start..<end))
        return edits
    }

    // MARK: Einfügen

    /// Fügt `text` hinter dem letzten Element ein – in eigener Zeile mit dessen Einrückung, wenn es in eigener Zeile
    /// steht, sonst in derselben Zeile. Ein nachgestelltes Komma des letzten Elements bleibt Stil: Das neue bekommt auch
    /// eins. Ein leerer Container erhält `text` direkt hinter der öffnenden Klammer – in eigener Zeile, eine Stufe
    /// tiefer als die schließende Klammer, wenn diese in eigener Zeile steht.
    private static func insertion(of text: [UInt8], into container: JSONContainerSpan, of document: ConfigDocument) -> ByteEdit {
        let bytes = document.bytes
        guard let last = container.items.last else {
            guard let closing = ConfigText.indentation(before: container.close, in: bytes),
                  ConfigText.lineStart(of: container.close, in: bytes) > container.open else {
                return .insert(text, at: container.open + 1)
            }
            return .insert(ConfigText.newline(of: bytes) + closing + ConfigText.indentationUnit(of: bytes) + text, at: container.open + 1)
        }
        let separator = ConfigText.indentation(before: last.start, in: bytes).map { ConfigText.newline(of: bytes) + $0 }
            ?? [UInt8(ascii: " ")]
        if let comma = last.comma {
            return .insert(separator + text + [UInt8(ascii: ",")], at: comma + 1)
        }
        return .insert([UInt8(ascii: ",")] + separator + text, at: last.end)
    }
}
