/// Lage eines Elements in einem JSON-Container: Objekt-Mitglied (ab dem Schlüssel) oder Array-Element. Nur
/// Byte-Positionen im Dokument ohne BOM, nie Inhalte; die Werte liefert der Baum in derselben Reihenfolge
/// (`ConfigObject.members` bzw. die Array-Elemente, doppelte Schlüssel eingeschlossen).
///
/// Ausnahme geschwärzte Arrays: Steht ein festgehaltenes Array unter einem geschwärzten Schlüssel, nennt die Lage seine
/// Elemente, der Baum hat an der Stelle aber nur `.redacted` – Positionen und Baum lassen sich dort nicht zuordnen.
struct JSONItemSpan: Hashable, Sendable {
    /// Anfang des Schlüssels (`"`) bzw. des Elements.
    let start: Int
    /// Anfang des Werts; bei Array-Elementen gleich `start`.
    let valueStart: Int
    /// Ende des Werts (exklusiv).
    let end: Int
    /// Position des Kommas hinter dem Wert (trennend oder nachgestellt); `nil` beim letzten Element ohne Komma.
    let comma: Int?
}

/// Lage eines Objekts oder Arrays: öffnende und schließende Klammer sowie die Elemente in Dokumentreihenfolge.
struct JSONContainerSpan: Hashable, Sendable {
    /// Position von `{` bzw. `[`.
    let open: Int
    /// Position von `}` bzw. `]`.
    let close: Int
    let items: [JSONItemSpan]
}

/// Lage der angefragten Container eines JSON-Dokuments (`JSONConfigParser.recordedContainers`).
struct JSONLayout: Hashable, Sendable {
    /// Container je Schlüsselpfad; mehrere, wenn ein Schlüssel auf dem Weg doppelt vorkommt.
    var containers: [[String]: [JSONContainerSpan]] = [:]
}

/// Eine Anweisung eines TOML-Dokuments: Tabellenkopf oder Schlüssel-Wert-Paar auf oberster Ebene.
struct TOMLStatement: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case table, arrayTable, keyValue
    }

    let kind: Kind
    /// Kopf: seine Schlüssel. Schlüssel-Wert: Schlüssel des umgebenden Kopfes plus die (ggf. punktierten) Schlüssel.
    let path: [String]
    /// Schlüssel des Kopfes, unter dem die Anweisung steht (beim Kopf: seine eigenen; vor dem ersten Kopf: leer).
    /// Array-Ebenen fehlen hier wie in `path`: `[mcp_servers.x]` hinter `[[mcp_servers]]` hat denselben Pfad wie ohne
    /// das Array – der Editor lehnt Einträge unter einem `[[…]]` deshalb ab (`unsupportedLayout`).
    let tablePath: [String]
    /// Ab Zeilenanfang (mit Einrückung) bis einschließlich Zeilenende samt Kommentar; am Dateiende ohne Zeilenende.
    let range: Range<Int>
    /// Nur Schlüssel-Wert: Lage des Werts.
    let valueRange: Range<Int>?
}

/// Anweisungen eines TOML-Dokuments in Dokumentreihenfolge (`TOMLConfigParser.recordsLayout`).
struct TOMLLayout: Hashable, Sendable {
    var statements: [TOMLStatement] = []
}

/// Geparstes Dokument samt Lage – Grundlage aller textuellen Änderungen (Stufe 2).
///
/// `bytes` ist der ganze Inhalt der Datei ohne BOM, Geheimwerte eingeschlossen: nie loggen, nie in Fehlertexte.
/// `description` und `dump` nennen deshalb nur Format und Größe.
struct ConfigDocument: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Layout: Sendable {
        case json(JSONLayout)
        case toml(TOMLLayout)
    }

    let syntax: ConfigSyntax
    let bytes: [UInt8]
    let tree: ConfigValue
    let layout: Layout

    /// Parst `bytes` (ohne BOM) mit `redaction` und hält bei JSON die Lage der `containers` fest, bei TOML alle
    /// Anweisungen. Werte unter geschwärzten Schlüsseln bleiben wie beim Scan ungelesen.
    init(bytes: [UInt8], syntax: ConfigSyntax, redaction: ConfigRedaction, containers: Set<[String]>) throws(ConfigParseError) {
        self.syntax = syntax
        self.bytes = bytes
        (tree, layout) = try ConfigParsing.parse(bytes, syntax: syntax, redaction: redaction, recording: containers)
    }

    var description: String { "ConfigDocument(\(syntax.rawValue), \(bytes.count) Bytes)" }

    var debugDescription: String { description }

    var customMirror: Mirror { Mirror(self, children: ["syntax": syntax, "byteCount": bytes.count]) }
}
