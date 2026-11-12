import Foundation

/// Eine eingebundene Fremdkomponente laut `ThirdPartyNotices.json` im App-Paket (#519). Version und Revision müssen zur
/// tatsächlich eingebundenen Fassung passen; das prüft `scripts/tests/test_third_party_notices.py` gegen `Package.resolved`.
public struct ThirdPartyNotice: Decodable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let revision: String
    public let projectURL: URL
    /// Dateiname des Lizenztexts in den Ressourcen des App-Pakets, 1:1 aus dem Paket der eingebundenen Version.
    public let licenseFile: String

    public init(name: String, version: String, revision: String, projectURL: URL, licenseFile: String) {
        self.name = name
        self.version = version
        self.revision = revision
        self.projectURL = projectURL
        self.licenseFile = licenseFile
    }
}

/// Eine Fremdkomponente samt vollständigem Lizenztext.
public struct ThirdPartyLicense: Identifiable, Equatable, Sendable {
    public let notice: ThirdPartyNotice
    public let text: String

    public init(notice: ThirdPartyNotice, text: String) {
        self.notice = notice
        self.text = text
    }

    public var id: String { notice.name }
}

/// Lädt die Drittanbieter-Lizenzen aus den Ressourcen. Fehlt das Verzeichnis oder ein Lizenztext, gibt es einen Fehler
/// statt einer leeren oder unvollständigen Liste: Die Lizenzen verlangen, dass die Texte jeder Kopie beiliegen.
public enum ThirdPartyNotices {
    public static let manifestFile = "ThirdPartyNotices.json"

    public enum LoadError: Error, Equatable {
        case missingManifest
        case emptyManifest
        case missingLicense(String)
    }

    public static func load(fromResources directory: URL) throws -> [ThirdPartyLicense] {
        guard let manifest = try? Data(contentsOf: directory.appending(path: manifestFile)) else {
            throw LoadError.missingManifest
        }
        return try load(manifest: manifest) { file in
            try String(contentsOf: directory.appending(path: file), encoding: .utf8)
        }
    }

    /// - Parameter licenseText: liefert den Inhalt einer Lizenzdatei zu ihrem Namen.
    public static func load(manifest: Data, licenseText: (String) throws -> String) throws -> [ThirdPartyLicense] {
        let notices = try JSONDecoder().decode([ThirdPartyNotice].self, from: manifest)
        guard !notices.isEmpty else { throw LoadError.emptyManifest }
        return try notices.map { notice in
            let file = notice.licenseFile
            // Nur Dateien direkt in den Ressourcen; kein Pfad hinaus.
            guard isPlainFileName(file), let text = try? licenseText(file),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LoadError.missingLicense(file)
            }
            return ThirdPartyLicense(notice: notice, text: text)
        }
    }

    private static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
    }
}
