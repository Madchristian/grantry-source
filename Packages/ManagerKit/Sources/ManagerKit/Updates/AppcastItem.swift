import Foundation

/// Ein gültiger Eintrag des Update-Feeds (Spec Update-Hinweis §2).
public struct AppcastItem: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let minimumSystemVersion: SystemVersion?
    public let releaseNotesURL: URL?
    public let downloadURL: URL
    public let length: Int?
    public let publishedAt: Date?

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
        static let enclosureAttributes = Set(["url", "length"] + Field.allCases.map(\.rawValue))

        var fields: [Field: String] = [:]
        var enclosure: [String: String] = [:]

        /// Wert aus einem Kind-Element, ersatzweise aus einem gleichnamigen `enclosure`-Attribut (ältere Feeds).
        func value(_ field: Field) -> String? {
            fields[field] ?? enclosure[field.rawValue]
        }
    }

    /// `nil`, wenn ein Pflichtfeld fehlt oder ungültig ist oder ein Link nicht auf `UpdateFeed.host` zeigt.
    init?(_ raw: Raw) {
        guard let build = raw.value(.build).flatMap(Int.init),
              let version = raw.value(.shortVersion), !version.isEmpty,
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
        publishedAt = raw.fields[.publishedAt].flatMap(Self.date(rfc822:))
    }

    private static func date(rfc822 text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text)
    }
}
