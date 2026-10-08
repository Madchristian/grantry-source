import Foundation

/// Ein Eintrag aus `sfltool dumpbtm`.
struct BTMRecord: Hashable, Sendable {
    enum ItemType: Hashable, Sendable {
        case app, loginItem, agent, daemon, legacyAgent, legacyDaemon, developer
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "app": self = .app
            case "login item": self = .loginItem
            case "agent": self = .agent
            case "daemon": self = .daemon
            case "legacy agent": self = .legacyAgent
            case "legacy daemon": self = .legacyDaemon
            case "developer": self = .developer
            default: self = .other(raw)
            }
        }
    }

    var name: String
    var type: ItemType
    var isEnabled: Bool
    /// UID des Abschnitts `Records for UID …`, in dem der Eintrag steht; `nil` ohne Abschnittskopf.
    var uid: Int?
    var identifier: String?
    var bundleID: String?
    var teamID: String?
    var url: String?
    var executablePath: String?
    var parentIdentifier: String?

    /// Bundle-ID des Eltern-Eintrags: `Parent Identifier` hat die Form `<typ>.<bundle-id>`, z. B. `2.com.docker.docker`.
    /// Legacy-Plists verweisen stattdessen auf einen `developer`-Eintrag (z. B. `Docker Inc`) – dann `nil`.
    var parentBundleID: String? { parentIdentifier.flatMap(Self.strippingTypePrefix) }

    /// `Identifier` ohne Typ-Präfix, z. B. `8.com.openai.chat-helper` → `com.openai.chat-helper` (bei Agents und
    /// Daemons das launchd-Label); `nil` für Kennungen ohne Präfix wie `Unknown Developer`.
    var unprefixedIdentifier: String? { identifier.flatMap(Self.strippingTypePrefix) }

    /// `<typ>.<kennung>` → `<kennung>`; `nil`, wenn kein numerisches Typ-Präfix oder keine Kennung folgt.
    private static func strippingTypePrefix(_ value: String) -> String? {
        guard let dot = value.firstIndex(of: "."), Int(value[..<dot]) != nil else { return nil }
        let rest = value[value.index(after: dot)...]
        return rest.isEmpty ? nil : String(rest)
    }
}

/// Zerlegt die Textausgabe von `sfltool dumpbtm` in Einträge (`#N:`-Blöcke mit `Schlüssel: Wert`-Zeilen).
///
/// Tolerant gegenüber unbekannten Schlüsseln und Typen, Leerzeilen, CRLF und mehreren `Records for UID …`-Abschnitten.
/// Eingerückte Unterzeilen wie `#1: 16.com.foo` unter `Embedded Item Identifiers:` tragen einen Wert und beginnen
/// deshalb keinen neuen Eintrag.
enum BTMParser {
    static func parse(_ output: String) -> [BTMRecord] {
        var records: [BTMRecord] = []
        var uid: Int?
        var fields: [String: String]?

        func flush() {
            if let fields, let record = record(from: fields, uid: uid) { records.append(record) }
            fields = nil
        }

        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isRecordStart(line) {
                flush()
                fields = [:]
            } else if line.hasPrefix("====") {
                flush()
            } else if line.hasPrefix(sectionPrefix) {
                flush()
                uid = Int(line.dropFirst(sectionPrefix.count).prefix { !$0.isWhitespace && $0 != ":" })
            } else if fields != nil, let (key, value) = keyValue(line), fields?[key] == nil {
                // Erster Wert gewinnt: eingebettete Unterzeilen dürfen Felder des Eintrags nicht überschreiben.
                fields?[key] = value
            }
        }
        flush()
        return records
    }

    /// `true`, wenn `output` mindestens einen `Records for UID …`-Kopf enthält – das hat jeder echte Dump,
    /// auch einer ohne Einträge.
    static func containsSection(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(sectionPrefix)
        }
    }

    /// `#12:` ohne Wert dahinter.
    private static func isRecordStart(_ line: String) -> Bool {
        line.hasPrefix("#") && line.hasSuffix(":") && line.count > 2 && Int(line.dropFirst().dropLast()) != nil
    }

    /// Kopf eines Abschnitts, z. B. `Records for UID 501 : …`.
    private static let sectionPrefix = "Records for UID "

    /// Trennt am ersten Doppelpunkt; Werte wie `file:///…` bleiben dadurch vollständig.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func record(from fields: [String: String], uid: Int?) -> BTMRecord? {
        guard let rawName = fields["Name"] else { return nil }
        /// `sfltool` schreibt fehlende Werte als `(null)`.
        func value(_ key: String) -> String? {
            fields[key].flatMap { $0 == nullValue ? nil : $0 }
        }
        return BTMRecord(
            name: value("Name") ?? value("Identifier") ?? rawName,
            type: .init(stripHexSuffix(fields["Type"] ?? "")),
            isEnabled: isEnabled(dispositionFlags(fields["Disposition"] ?? "")),
            uid: uid,
            identifier: value("Identifier"),
            bundleID: value("Bundle Identifier"),
            teamID: value("Team Identifier"),
            url: value("URL"),
            executablePath: value("Executable Path"),
            parentIdentifier: value("Parent Identifier")
        )
    }

    private static let nullValue = "(null)"

    /// Wirksam aktiv nur, wenn die App den Eintrag registriert hat (`enabled`) und der Benutzer ihn in den
    /// Systemeinstellungen nicht ausgeschaltet hat (`disallowed`).
    private static func isEnabled(_ flags: Set<String>) -> Bool {
        flags.contains("enabled") && !flags.contains("disallowed")
    }

    /// `"[enabled, allowed, visible] (0xb)"` → `["enabled", "allowed", "visible"]`.
    private static func dispositionFlags(_ value: String) -> Set<String> {
        guard let open = value.firstIndex(of: "["), let close = value[open...].firstIndex(of: "]") else { return [] }
        return Set(value[value.index(after: open)..<close].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
    }

    /// `"login item (0x4)"` → `"login item"`.
    private static func stripHexSuffix(_ value: String) -> String {
        guard let paren = value.range(of: " (0x", options: .backwards) else { return value }
        return String(value[..<paren.lowerBound])
    }
}
