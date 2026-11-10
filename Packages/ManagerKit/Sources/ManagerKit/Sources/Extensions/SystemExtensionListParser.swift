import Foundation
import GrantryShared

/// Liest die Ausgabe von `systemextensionsctl list` (läuft ohne Root).
///
/// Die Ausgabe ist keine zugesicherte Schnittstelle, daher defensiv: Kopfzeile `N extension(s)`, je Art ein Abschnitt
/// `--- com.apple.system_extension.<art> (…)` mit Spaltenkopf, Einträge mit Tabulatoren getrennt
/// (`enabled`, `active`, `teamID`, `bundleID (version)`, `name`, `[state]`). Spaltenbreiten spielen keine Rolle.
/// Enthält der Name selbst Tabulatoren, werden die mittleren Felder mit Leerzeichen zusammengefügt. Unbekannte Arten
/// und Zustände bleiben im Wortlaut erhalten; nicht auswertbare Zeilen zählen in `unreadableLineCount`.
public enum SystemExtensionListParser {
    /// Ohne Kopfzeile ist das Format unbekannt.
    public struct FormatError: Error, Equatable {}

    private static let sectionPrefix = "--- "
    private static let columnHeaderPrefix = "enabled\t"
    private static let headerSuffix = " extension(s)"
    private static let marker = "*"

    public static func parse(_ output: String) throws -> SystemExtensionList {
        var lines = output.split(whereSeparator: \.isNewline).map(String.init)[...]
        guard let header = lines.popFirst(), let declaredCount = declaredCount(in: header) else { throw FormatError() }
        var category: SystemExtensionCategory?
        var extensions: [SystemExtension] = []
        var unreadable = 0
        for line in lines where !line.allSatisfy(\.isWhitespace) {
            if line.hasPrefix(sectionPrefix) {
                category = SystemExtensionCategory(identifier: sectionIdentifier(in: line))
            } else if line.hasPrefix(columnHeaderPrefix) {
                continue
            } else if let category, let entry = entry(in: line, category: category) {
                extensions.append(entry)
            } else {
                unreadable += 1
            }
        }
        return SystemExtensionList(extensions: extensions, declaredCount: declaredCount, unreadableLineCount: unreadable)
    }

    /// `5` aus `5 extension(s)`.
    private static func declaredCount(in line: String) -> Int? {
        guard line.hasSuffix(headerSuffix) else { return nil }
        return Int(line.dropLast(headerSuffix.count))
    }

    /// `com.apple.system_extension.driver_extension` aus `--- com.apple.system_extension.driver_extension (Go to …)`.
    private static func sectionIdentifier(in line: String) -> String {
        let rest = line.dropFirst(sectionPrefix.count)
        let identifier = rest.prefix { !$0.isWhitespace }
        return ExtensionText.identifier(String(identifier))
    }

    private static func entry(in line: String, category: SystemExtensionCategory) -> SystemExtension? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6, let stateText = bracketed(fields[fields.count - 1]),
              let (bundleID, version, buildVersion) = identity(in: fields[3]) else { return nil }
        let name = fields[4..<(fields.count - 1)].joined(separator: " ")
        let teamID = fields[2].trimmingCharacters(in: .whitespaces)
        return SystemExtension(
            category: category,
            isEnabled: fields[0].trimmingCharacters(in: .whitespaces) == marker,
            isActive: fields[1].trimmingCharacters(in: .whitespaces) == marker,
            teamID: teamID.isEmpty || teamID == "-" ? nil : ExtensionText.identifier(teamID),
            bundleID: bundleID,
            version: version,
            buildVersion: buildVersion,
            name: ExtensionText.name(name),
            state: SystemExtensionState(text: ExtensionText.identifier(stateText))
        )
    }

    /// Inhalt von `[…]`; `nil` ohne Klammern.
    private static func bracketed(_ field: String) -> String? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    /// Bundle-ID, Version und Build aus `com.example.ext (1.2/345)`; die Version steht in der letzten Klammer.
    private static func identity(in field: String) -> (String, String, String?)? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
        let bundleID = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let versions = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        guard !bundleID.isEmpty, !versions.isEmpty else { return nil }
        let parts = versions.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let version = ExtensionText.version(parts[0])
        let build = parts.count > 1 ? ExtensionText.version(parts[1]) : nil
        return (ExtensionText.identifier(bundleID), version, build)
    }
}
