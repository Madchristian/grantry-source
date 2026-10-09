import Foundation
import os

public enum AppcastError: Error, Equatable {
    /// Kein wohlgeformtes XML.
    case malformed
    /// Der Feed überschreitet eine Grenze aus `UpdateFeed` (Größe, Einträge, Feldlänge, Verschachtelung).
    case tooLarge
}

/// Liest den Update-Feed im Sparkle-2-Format; ungültige Einträge werden übersprungen und protokolliert.
///
/// Setzt das Namespace-Präfix `sparkle` voraus (der Feed wird von `scripts/appcast.swift` erzeugt) und übernimmt nur
/// direkte Kinder von `<item>`; verschachtelte Elemente wie `<sparkle:deltas>` bleiben unberücksichtigt.
/// Die optionale DMG-Prüfsumme wird über ihre Namespace-URI erkannt, unabhängig vom Präfix.
///
/// Gegen einen Feed, der Speicher und Parserzeit flutet, gelten die Grenzen aus `UpdateFeed`. Überschreitet das
/// Dokument die Größe, ein Feld die Länge oder die Verschachtelung die Tiefe, bricht der Parser ab und wirft
/// `AppcastError.tooLarge`. Die Eintragszahl ist dagegen **kein Fehler**: Der Feed wächst mit jedem Release, und ein
/// Fehler sperrte jeden Client dauerhaft aus. Ab `UpdateFeed.maximumItems` bricht der Parser nur ab und liefert die
/// bis dahin gelesenen Einträge; die neuesten stehen oben (`scripts/appcast.swift`). Gesammelt wird nur der Text der
/// ausgewerteten Felder (`AppcastItem.Raw.Field`).
public enum AppcastParser {
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "updates")

    public static func items(from data: Data) throws -> [AppcastItem] {
        guard data.count <= UpdateFeed.maximumFeedBytes else {
            logger.notice("Appcast verworfen: Dokument größer als \(UpdateFeed.maximumFeedBytes) Byte")
            throw AppcastError.tooLarge
        }
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = collector
        let parsed = parser.parse()
        // Beides nach `abortParsing()`, das `parse()` scheitern lässt: eine harte Grenze hat Vorrang vor `malformed`; nach
        // der Eintragsgrenze zählt, was bis dahin gelesen wurde.
        guard !collector.exceededLimit else { throw AppcastError.tooLarge }
        guard parsed || collector.truncated else { throw AppcastError.malformed }
        return collector.items.compactMap { raw in
            guard let item = AppcastItem(raw) else {
                let summary = raw.value(.build) ?? "ohne Build"
                logger.notice("Appcast-Eintrag übersprungen (\(summary, privacy: .public))")
                return nil
            }
            return item
        }
    }

    /// Sammelt die Rohwerte aller `<item>`-Elemente und bricht ab, sobald eine Grenze aus `UpdateFeed` überschritten wird.
    /// Die Eintragsgrenze kürzt nur (`truncated`), die übrigen sind Fehler (`exceededLimit`).
    private final class Collector: NSObject, XMLParserDelegate {
        typealias Field = AppcastItem.Raw.Field

        var items: [AppcastItem.Raw] = []
        /// `true`, nachdem eine harte Grenze (Feld, Tiefe) den Lauf abgebrochen hat.
        private(set) var exceededLimit = false
        /// `true`, nachdem die Eintragsgrenze den Lauf abgebrochen hat; `items` bleibt gültig.
        private(set) var truncated = false
        private var isStopped: Bool { exceededLimit || truncated }
        private var current: AppcastItem.Raw?
        /// Anzahl der offenen Elemente unterhalb von `<item>`; 1 bedeutet: direktes Kind.
        private var depth = 0
        /// Anzahl aller gerade offenen Elemente im Dokument.
        private var openElements = 0
        /// Das direkte Kind von `<item>`, dessen Text gerade gesammelt wird; sonst `nil` (Text wird verworfen).
        private var collecting: Field?
        private var text = ""
        /// Namespace-Bindungen je Präfix; lokale Deklarationen gelten nur bis zum Ende ihres Elements.
        private var namespaces: [String: [String]] = [:]

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            guard !isStopped else { return }
            namespaces[prefix, default: []].append(namespaceURI)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            namespaces[prefix]?.removeLast()
            if namespaces[prefix]?.isEmpty == true { namespaces[prefix] = nil }
        }

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            guard !isStopped else { return }
            openElements += 1
            guard openElements <= UpdateFeed.maximumNestingDepth else {
                return abort(parser, "Verschachtelung tiefer als \(UpdateFeed.maximumNestingDepth) Elemente")
            }
            text = ""
            collecting = nil
            if current == nil {
                if name == "item" {
                    guard items.count < UpdateFeed.maximumItems else { return truncate(parser) }
                    current = AppcastItem.Raw()
                    depth = 0
                }
                return
            }
            depth += 1
            guard depth == 1 else { return }
            if name == "enclosure" {
                collectEnclosure(attributes, parser)
            }
            collecting = Field(rawValue: name)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(string, parser)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self), parser)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard !isStopped else { return }
            openElements -= 1
            guard let finished = current else { return }
            if depth == 0 {
                items.append(finished)
                current = nil
                return
            }
            if depth == 1, let field = collecting {
                current?.fields[field] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            collecting = nil
            depth -= 1
        }

        /// Hängt Text nur an, solange ein ausgewertetes Feld offen ist; ein zu langer Text bricht den Lauf ab.
        private func append(_ string: String, _ parser: XMLParser) {
            guard !isStopped, collecting != nil else { return }
            text += string
            if text.utf8.count > UpdateFeed.maximumFieldLength {
                abort(parser, "Feld länger als \(UpdateFeed.maximumFieldLength) Byte")
            }
        }

        /// Merkt nur die ausgewerteten Attribute; ein zu langer Wert bricht den Lauf ab.
        private func collectEnclosure(_ attributes: [String: String], _ parser: XMLParser) {
            var kept: [String: String] = [:]
            for (name, value) in attributes where AppcastItem.Raw.enclosureAttributes.contains(name) {
                guard value.utf8.count <= UpdateFeed.maximumFieldLength else {
                    return abort(parser, "Attribut länger als \(UpdateFeed.maximumFieldLength) Byte")
                }
                kept[name] = value
            }
            current?.enclosure = kept
            let checksums = attributes.filter { name, _ in
                let parts = name.split(separator: ":", omittingEmptySubsequences: false)
                return parts.count == 2 && parts[1] == "sha256"
                    && namespaces[String(parts[0])]?.last == AppcastItem.Raw.checksumNamespace
            }
            // Ungültige optionale Hashes bleiben ohne Auswirkung auf den Update-Hinweis. Auch überlange Werte
            // nicht speichern; nur die übrigen ausgewerteten Attribute unterliegen der harten Feldgrenze.
            current?.sha256 = checksums.count == 1 ? checksums.values.first.flatMap { $0.utf8.count == 64 ? $0 : nil } : nil
        }

        /// Hört bei der Eintragsgrenze auf; die bis dahin gelesenen (neuesten) Einträge bleiben erhalten.
        private func truncate(_ parser: XMLParser) {
            truncated = true
            logger.notice("Appcast gekürzt: nur die ersten \(UpdateFeed.maximumItems) Einträge gelesen")
            parser.abortParsing()
        }

        private func abort(_ parser: XMLParser, _ reason: String) {
            exceededLimit = true
            logger.notice("Appcast verworfen: \(reason, privacy: .public)")
            parser.abortParsing()
        }
    }
}
