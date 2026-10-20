import Foundation

/// Ein gültiger Eintrag des Update-Feeds (Spec Update-Hinweis §2).
public struct AppcastItem: Equatable, Sendable {
    /// Plausibilitätsgrenze für den Git-Commit-Zähler; der Checker begrenzt zusätzlich den Abstand zur Installation.
    static let maximumBuild = 10_000_000

    public let version: String
    public let build: Int
    public let minimumSystemVersion: SystemVersion?
    public let releaseNotesURL: URL?
    public let downloadURL: URL
    public let length: Int?
    /// Vom Feed gelieferte SHA-256-Prüfsumme des DMG; reine Integritäts-Gegenprobe, kein Echtheitsnachweis.
    public let sha256: String?
    public let publishedAt: Date?
    public let edSignature: String?

    /// Rohwerte eines `<item>`: die ausgewerteten Kind-Elemente und die Attribute von `<enclosure>`. Alles andere im
    /// Feed (etwa `<title>` oder `<description>`) wird beim Lesen gar nicht erst gesammelt (`UpdateFeed.maximumFieldLength`).
    struct Raw {
        /// Ausgewertete Kind-Elemente eines `<item>`, benannt wie im Feed; ältere Feeds tragen sie als Attribute von
        /// `<enclosure>`.
        enum Field: String, CaseIterable {
            case build = "sparkle:version"
            case shortVersion = "sparkle:shortVersionString"
            case minimumSystemVersion = "sparkle:minimumSystemVersion"
            case releaseNotesLink = "sparkle:releaseNotesLink"
            case publishedAt = "pubDate"
        }

        /// Attribute von `<enclosure>`, die gelesen werden: `url`, `length` und die Felder der älteren Feeds.
        static let enclosureAttributes = Set(["url", "length", "sparkle:edSignature"] + Field.allCases.map(\.rawValue))

        /// Eigene RSS-Erweiterung, siehe `scripts/appcast.swift` und RSS 2.0 § Extending RSS.
        static let checksumNamespace = "https://grantry.cstrube.de/xml-namespaces/appcast"

        var fields: [Field: String] = [:]
        var enclosure: [String: String] = [:]
        var sha256: String?

        /// Wert aus einem Kind-Element, ersatzweise aus einem gleichnamigen `enclosure`-Attribut (ältere Feeds).
        func value(_ field: Field) -> String? {
            fields[field] ?? enclosure[field.rawValue]
        }
    }

    /// `nil`, wenn ein Pflichtfeld fehlt oder ungültig ist oder ein Link nicht auf `UpdateFeed.host` zeigt.
    init?(_ raw: Raw) {
        guard let build = raw.value(.build).flatMap(Int.init), (1...Self.maximumBuild).contains(build),
              let version = raw.value(.shortVersion),
              version.wholeMatch(of: /[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,3}/) != nil,
              let download = raw.enclosure["url"].flatMap(URL.init(string:)), UpdateFeed.isAllowed(download)
        else { return nil }
        var releaseNotes: URL?
        if let text = raw.fields[.releaseNotesLink] {
            guard let url = URL(string: text), UpdateFeed.isAllowed(url) else { return nil }
            releaseNotes = url
        }
        var minimum: SystemVersion?
        if let text = raw.value(.minimumSystemVersion) {
            guard let parsed = SystemVersion(dotted: text) else { return nil }
            minimum = parsed
        }
        self.version = version
        self.build = build
        minimumSystemVersion = minimum
        releaseNotesURL = releaseNotes
        downloadURL = download
        length = raw.enclosure["length"].flatMap(Int.init)
        edSignature = raw.enclosure["sparkle:edSignature"]
        sha256 = raw.sha256.flatMap(Self.validSHA256)
        publishedAt = raw.fields[.publishedAt].flatMap(Self.date(rfc822:))
    }

    /// Brücke vom Sparkle-Parser; dieselben URL-/Versionsregeln wie beim bisherigen Feed gelten.
    public init?(version: String, build: String, downloadURL: URL, releaseNotesURL: URL?,
                 length: Int?, edSignature: String?, sha256: String?, minimumSystemVersion: String? = nil) {
        var raw = Raw()
        raw.fields = [.shortVersion: version, .build: build]
        raw.fields[.minimumSystemVersion] = minimumSystemVersion
        if let releaseNotesURL { raw.fields[.releaseNotesLink] = releaseNotesURL.absoluteString }
        raw.enclosure = ["url": downloadURL.absoluteString]
        if let length { raw.enclosure["length"] = String(length) }
        raw.enclosure["sparkle:edSignature"] = edSignature
        raw.sha256 = sha256
        self.init(raw)
    }

    /// Exakt 64 ASCII-Hexzeichen; kein Trimmen oder Akzeptieren ähnlich aussehender Unicode-Zeichen.
    private static func validSHA256(_ text: String) -> String? {
        guard text.utf8.count == 64, text.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return text.lowercased()
    }

    private static func date(rfc822 text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text)
    }
}
