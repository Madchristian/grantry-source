import Foundation
import Testing
@testable import ManagerKit

@Suite struct AppcastParserTests {
    /// Feed im Sparkle-2-Format mit den angegebenen `<item>`-Blöcken.
    static func feed(_ items: String...) -> Data {
        feed(items: items)
    }

    static func feed(items: [String]) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Grantry</title>
            \(items.joined(separator: "\n"))
          </channel>
        </rss>
        """.utf8)
    }

    static func item(
        version: String = "2026.10.5", build: String = "280", minimumSystem: String? = "27.0",
        notes: String? = "https://grantry.cstrube.de/release-notes/2026.10.5.html",
        download: String = "https://grantry.cstrube.de/download/Grantry-2026.10.5.dmg"
    ) -> String {
        """
        <item>
          <title>\(version)</title>
          <sparkle:version>\(build)</sparkle:version>
          <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
          \(minimumSystem.map { "<sparkle:minimumSystemVersion>\($0)</sparkle:minimumSystemVersion>" } ?? "")
          \(notes.map { "<sparkle:releaseNotesLink>\($0)</sparkle:releaseNotesLink>" } ?? "")
          <pubDate>Sun, 04 Oct 2026 08:42:00 +0200</pubDate>
          <enclosure url="\(download)" length="2661986" type="application/octet-stream"/>
        </item>
        """
    }

    @Test func readsAValidItem() throws {
        let items = try AppcastParser.items(from: Self.feed(Self.item()))
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.version == "2026.10.5")
        #expect(item.build == 280)
        #expect(item.minimumSystemVersion == SystemVersion(major: 27))
        #expect(item.releaseNotesURL == URL(string: "https://grantry.cstrube.de/release-notes/2026.10.5.html"))
        #expect(item.downloadURL == URL(string: "https://grantry.cstrube.de/download/Grantry-2026.10.5.dmg"))
        #expect(item.length == 2_661_986)
        #expect(item.sha256 == nil)
        #expect(item.publishedAt == Date(timeIntervalSince1970: 1_791_096_120))
    }

    @Test(arguments: ["2026.1.1", "2026.10.81", "2026.10.301"])
    func acceptsCalVerIncludingSameDaySuffix(version: String) throws {
        let items = try AppcastParser.items(from: Self.feed(Self.item(version: version)))
        #expect(items.first?.version == version)
    }

    @Test(arguments: ["", "1.2.3", "2026.100.1", "2026.10.1000", "2026.10.5-beta",
                      "2026.10.5\ninstructions", "２０２６.10.5", "2026..5"])
    func invalidVersionsDoNotDiscardValidEntries(version: String) throws {
        let items = try AppcastParser.items(from: Self.feed(Self.item(version: version), Self.item()))
        #expect(items.map(\.version) == ["2026.10.5"])
    }

    @Test(arguments: ["0", "-1", "10000001", String(Int.max)])
    func implausibleBuildsDoNotDiscardValidEntries(build: String) throws {
        let items = try AppcastParser.items(from: Self.feed(Self.item(build: build), Self.item()))
        #expect(items.map(\.build) == [280])
    }

    @Test func acceptsTheAbsoluteBuildLimit() throws {
        let items = try AppcastParser.items(from: Self.feed(Self.item(build: "10000000")))
        #expect(items.first?.build == 10_000_000)
    }

    @Test func optionalFieldsMayBeMissing() throws {
        let item = try #require(try AppcastParser.items(from: Self.feed(Self.item(minimumSystem: nil, notes: nil))).first)
        #expect(item.minimumSystemVersion == nil)
        #expect(item.releaseNotesURL == nil)
        #expect(item.sha256 == nil)
    }

    private static let checksum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private static let checksumNamespace = "https://grantry.cstrube.de/xml-namespaces/appcast"

    private static func item(checksum: String, prefix: String = "grantry", namespace: String = checksumNamespace) -> String {
        item().replacingOccurrences(
            of: "<enclosure ", with: "<enclosure xmlns:\(prefix)=\"\(namespace)\" \(prefix):sha256=\"\(checksum)\" "
        )
    }

    @Test(arguments: [checksum, checksum.uppercased()])
    func readsAndNormalizesSHA256(checksum: String) throws {
        let item = try #require(try AppcastParser.items(from: Self.feed(Self.item(checksum: checksum))).first)
        #expect(item.sha256 == Self.checksum)
    }

    @Test(arguments: [
        "", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
        String(repeating: "g", count: 64), String(repeating: "é", count: 64),
        String(repeating: "Ａ", count: 64), " " + checksum, checksum + " ",
        checksum + "&#10;", String(repeating: "a", count: UpdateFeed.maximumFieldLength + 1),
    ])
    func ignoresInvalidSHA256WithoutDroppingTheUpdate(checksum: String) throws {
        let items = try AppcastParser.items(from: Self.feed(Self.item(checksum: checksum)))
        #expect(items.map(\.build) == [280])
        #expect(items.first?.sha256 == nil)
    }

    @Test func checksumUsesNamespaceURIAndRespectsItsScope() throws {
        let valid = Self.item(checksum: Self.checksum, prefix: "digest")
        let wrongNamespace = Self.item(checksum: Self.checksum, namespace: "urn:other")
        let plain = Self.item().replacingOccurrences(of: "<enclosure ", with: "<enclosure sha256=\"\(Self.checksum)\" ")
        let items = try AppcastParser.items(from: Self.feed(valid, wrongNamespace, plain, Self.item()))
        #expect(items.count == 4)
        #expect(items.map(\.sha256) == [Self.checksum, nil, nil, nil])
    }

    @Test func inheritedChecksumNamespaceIsRestoredAfterLocalOverride() throws {
        let inherited = Self.item().replacingOccurrences(of: "<enclosure ", with: "<enclosure digest:sha256=\"\(Self.checksum)\" ")
        let wrong = Self.item(checksum: Self.checksum, prefix: "digest", namespace: "urn:other")
        let feed = String(decoding: Self.feed(inherited, wrong, inherited), as: UTF8.self)
            .replacingOccurrences(of: "<channel>", with: "<channel xmlns:digest=\"\(Self.checksumNamespace)\">")
        let items = try AppcastParser.items(from: Data(feed.utf8))
        #expect(items.map(\.sha256) == [Self.checksum, nil, Self.checksum])
    }

    @Test func nestedChecksumDoesNotOverrideTheDownloadChecksum() throws {
        let delta = "<sparkle:deltas>\(Self.item(checksum: String(repeating: "b", count: 64)))</sparkle:deltas>"
        let item = Self.item(checksum: Self.checksum).replacingOccurrences(of: "</item>", with: "\(delta)</item>")
        let parsed = try #require(try AppcastParser.items(from: Self.feed(item)).first)
        #expect(parsed.sha256 == Self.checksum)
    }

    @Test func keepsAllValidItems() throws {
        let items = try AppcastParser.items(from: Self.feed(
            Self.item(version: "2026.10.5", build: "280"), Self.item(version: "2026.10.4", build: "276")
        ))
        #expect(items.map(\.build) == [280, 276])
    }

    @Test(arguments: [
        AppcastParserTests.item(build: "abc"),
        AppcastParserTests.item(build: ""),
        AppcastParserTests.item(download: "https://evil.example/Grantry.dmg"),
        AppcastParserTests.item(download: "http://grantry.cstrube.de/download/Grantry-2026.10.5.dmg"),
        AppcastParserTests.item(notes: "https://evil.example/notes.html"),
        AppcastParserTests.item(minimumSystem: "siebenundzwanzig"),
    ])
    func skipsInvalidItemsButKeepsTheRest(invalid: String) throws {
        let items = try AppcastParser.items(from: Self.feed(invalid, Self.item(version: "2026.10.4", build: "276")))
        #expect(items.map(\.build) == [276])
    }

    /// Roher `<item>`-Block mit allen Pflichtfeldern, abzüglich des übergebenen.
    private static func rawItem(omitting omitted: String) -> String {
        let version = omitted == "version" ? "" : "<sparkle:version>280</sparkle:version>"
        let shortVersion = omitted == "shortVersionString"
            ? "" : "<sparkle:shortVersionString>2026.10.5</sparkle:shortVersionString>"
        let url = omitted == "enclosureURL"
            ? "" : #" url="https://grantry.cstrube.de/download/Grantry-2026.10.5.dmg""#
        return """
        <item>
          <title>2026.10.5</title>
          \(version)
          \(shortVersion)
          <enclosure\(url) length="2661986" type="application/octet-stream"/>
        </item>
        """
    }

    @Test(arguments: ["version", "shortVersionString", "enclosureURL"])
    func skipsItemsWithoutARequiredField(missing: String) throws {
        let items = try AppcastParser.items(from: Self.feed(
            Self.rawItem(omitting: missing), Self.item(version: "2026.10.4", build: "276")
        ))
        #expect(items.map(\.build) == [276])
    }

    @Test func readsRequiredFieldsFromEnclosureAttributesOfOlderFeeds() throws {
        let legacy = """
        <item>
          <title>2026.10.5</title>
          <enclosure url="https://grantry.cstrube.de/download/Grantry-2026.10.5.dmg" length="2661986"
                     type="application/octet-stream" sparkle:version="280" sparkle:shortVersionString="2026.10.5"
                     sparkle:minimumSystemVersion="27.0"/>
        </item>
        """
        let item = try #require(try AppcastParser.items(from: Self.feed(legacy)).first)
        #expect(item.build == 280)
        #expect(item.version == "2026.10.5")
        #expect(item.minimumSystemVersion == SystemVersion(major: 27))
        #expect(item.sha256 == nil)
    }

    @Test func nestedElementsDoNotOverrideTheMainItem() throws {
        let withDeltas = """
        <item>
          <title>2026.10.5</title>
          <sparkle:version>280</sparkle:version>
          <sparkle:shortVersionString>2026.10.5</sparkle:shortVersionString>
          <enclosure url="https://grantry.cstrube.de/download/Grantry-2026.10.5.dmg" length="2661986"
                     type="application/octet-stream"/>
          <sparkle:deltas>
            <enclosure url="https://grantry.cstrube.de/download/Grantry-280-276.delta" length="1234"
                       type="application/octet-stream" sparkle:deltaFrom="276"/>
            <sparkle:version>999</sparkle:version>
            <sparkle:shortVersionString>delta</sparkle:shortVersionString>
          </sparkle:deltas>
        </item>
        """
        let item = try #require(try AppcastParser.items(from: Self.feed(withDeltas)).first)
        #expect(item.downloadURL == URL(string: "https://grantry.cstrube.de/download/Grantry-2026.10.5.dmg"))
        #expect(item.length == 2_661_986)
        #expect(item.build == 280)
        #expect(item.version == "2026.10.5")
    }

    @Test func readsCDATASections() throws {
        let cdata = Self.item().replacingOccurrences(
            of: "<sparkle:shortVersionString>2026.10.5</sparkle:shortVersionString>",
            with: "<sparkle:shortVersionString><![CDATA[2026.10.5]]></sparkle:shortVersionString>"
        )
        let item = try #require(try AppcastParser.items(from: Self.feed(cdata)).first)
        #expect(item.version == "2026.10.5")
    }

    @Test func malformedXMLThrows() {
        #expect(throws: AppcastError.malformed) {
            try AppcastParser.items(from: Data("<rss><channel><item>".utf8))
        }
    }

    // MARK: Grenzen (#103)

    /// `<item>` mit Pflichtfeldern, dessen Anzeige-Version `version` ist.
    private static func item(shortVersion version: String) -> String {
        item().replacingOccurrences(of: "2026.10.5</sparkle:shortVersionString>", with: "\(version)</sparkle:shortVersionString>")
    }

    @Test func readsExactlyTheMaximumNumberOfItems() throws {
        let items = try AppcastParser.items(from: Self.feed(items: Array(repeating: Self.item(), count: UpdateFeed.maximumItems)))
        #expect(items.count == UpdateFeed.maximumItems)
    }

    /// `count` Einträge, neueste zuerst (wie `scripts/appcast.swift` sie schreibt): Build `count + 100` oben, 101 unten.
    private static func newestFirstFeed(count: Int) -> Data {
        feed(items: (1...count).reversed().map { item(version: "2026.1.\($0)", build: "\($0 + 100)") })
    }

    @Test func keepsTheFirstItemsWhenThereAreMoreThanTheLimit() throws {
        // Der Appcast wächst mit jedem Release. Ein Fehler hier sperrte jeden Client dauerhaft aus; also zählen die
        // neuesten (obersten) Einträge weiter, und der Rest wird ignoriert.
        let count = UpdateFeed.maximumItems + 1
        let items = try AppcastParser.items(from: Self.newestFirstFeed(count: count))
        #expect(items.count == UpdateFeed.maximumItems)
        #expect(items.first?.build == count + 100)
        #expect(items.last?.build == 102)
        #expect(!items.contains { $0.build == 101 })
    }

    @Test func staysLenientEvenWithMuchMoreItems() throws {
        let items = try AppcastParser.items(from: Self.newestFirstFeed(count: UpdateFeed.maximumItems * 3))
        #expect(items.count == UpdateFeed.maximumItems)
    }

    @Test func ignoresWhatFollowsTheItemLimit() throws {
        // Nach dem Abbruch wird nichts mehr gelesen, auch kein kaputtes XML ab dem ersten überzähligen Eintrag.
        let valid = Array(repeating: Self.item(), count: UpdateFeed.maximumItems)
        let items = try AppcastParser.items(from: Self.feed(items: valid + ["<item><unclosed>"]))
        #expect(items.count == UpdateFeed.maximumItems)
    }

    @Test func readsAFieldExactlyAtTheLimit() throws {
        // Ein gültiger Link kann die Feldgrenze erreichen; eine CalVer-Version ist zwingend kürzer.
        let prefix = "https://grantry.cstrube.de/"
        let notes = prefix + String(repeating: "a", count: UpdateFeed.maximumFieldLength - prefix.utf8.count)
        let item = try #require(try AppcastParser.items(from: Self.feed(Self.item(notes: notes))).first)
        #expect(item.releaseNotesURL?.absoluteString == notes)
    }

    @Test func rejectsAFieldAboveTheLimit() {
        let feed = Self.feed(Self.item(shortVersion: String(repeating: "1", count: UpdateFeed.maximumFieldLength + 1)))
        #expect(throws: AppcastError.tooLarge) { try AppcastParser.items(from: feed) }
    }

    @Test func countsTheBytesNotTheCharactersOfAField() {
        // „ä“ sind 2 Byte: 2049 davon überschreiten 4096 Byte, obwohl es weniger als 4096 Zeichen sind.
        let feed = Self.feed(Self.item(shortVersion: String(repeating: "ä", count: UpdateFeed.maximumFieldLength / 2 + 1)))
        #expect(throws: AppcastError.tooLarge) { try AppcastParser.items(from: feed) }
    }

    @Test func rejectsAnOversizedCDATAField() {
        let long = String(repeating: "1", count: UpdateFeed.maximumFieldLength + 1)
        let feed = Self.feed(Self.item(shortVersion: "<![CDATA[\(long)]]>"))
        #expect(throws: AppcastError.tooLarge) { try AppcastParser.items(from: feed) }
    }

    @Test func rejectsAnOversizedEnclosureAttribute() {
        let path = String(repeating: "a", count: UpdateFeed.maximumFieldLength)
        let feed = Self.feed(Self.item(download: "https://grantry.cstrube.de/download/\(path).dmg"))
        #expect(throws: AppcastError.tooLarge) { try AppcastParser.items(from: feed) }
    }

    @Test func ignoresTheTextOfFieldsItDoesNotRead() throws {
        // Release Notes als `<description>` sind in Sparkle-Feeds üblich und dürfen groß sein (hier 500 KB).
        let description = "<description><![CDATA[\(String(repeating: "x", count: 500_000))]]></description>"
        let item = Self.item().replacingOccurrences(of: "<title>", with: "\(description)<title>")
        let items = try AppcastParser.items(from: Self.feed(item))
        #expect(items.map(\.build) == [280])
    }

    @Test func ignoresTheTextOfNestedElements() throws {
        let nested = "<sparkle:deltas><sparkle:version>\(String(repeating: "9", count: 100_000))</sparkle:version></sparkle:deltas>"
        let item = Self.item().replacingOccurrences(of: "</item>", with: "\(nested)</item>")
        #expect(try AppcastParser.items(from: Self.feed(item)).map(\.build) == [280])
    }

    /// Feed, in dessen `<channel>` `levels` Elemente ineinander liegen; mit `rss` und `channel` also `levels + 2` offene.
    private static func nested(levels: Int) -> Data {
        feed(String(repeating: "<x>", count: levels) + String(repeating: "</x>", count: levels))
    }

    @Test func readsTheDeepestAllowedNesting() throws {
        #expect(try AppcastParser.items(from: Self.nested(levels: UpdateFeed.maximumNestingDepth - 2)).isEmpty)
    }

    @Test func rejectsNestingAboveTheLimit() {
        let feed = Self.nested(levels: UpdateFeed.maximumNestingDepth - 1)
        #expect(throws: AppcastError.tooLarge) { try AppcastParser.items(from: feed) }
    }

    @Test func rejectsNestingInsideAnItemToo() {
        let deep = String(repeating: "<x>", count: UpdateFeed.maximumNestingDepth) + String(repeating: "</x>", count: UpdateFeed.maximumNestingDepth)
        let feed = Self.feed(Self.item().replacingOccurrences(of: "</item>", with: "\(deep)</item>"))
        #expect(throws: AppcastError.tooLarge) { try AppcastParser.items(from: feed) }
    }

    @Test func readsADocumentExactlyAtTheSizeLimit() throws {
        var data = Self.feed(Self.item())
        data.append(Data(repeating: UInt8(ascii: " "), count: UpdateFeed.maximumFeedBytes - data.count))
        #expect(data.count == UpdateFeed.maximumFeedBytes)
        #expect(try AppcastParser.items(from: data).count == 1)
    }

    @Test func rejectsADocumentAboveTheSizeLimit() {
        var data = Self.feed(Self.item())
        data.append(Data(repeating: UInt8(ascii: " "), count: UpdateFeed.maximumFeedBytes + 1 - data.count))
        #expect(throws: AppcastError.tooLarge) { try AppcastParser.items(from: data) }
    }

    @Test func limitsDoNotMaskMalformedXML() {
        #expect(throws: AppcastError.malformed) { try AppcastParser.items(from: Data("<rss><channel><item>".utf8)) }
    }

    // MARK: Echte Feeds

    private static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Der eingecheckte Feed und die Testfeeds der Abnahme müssen unter den Grenzen bleiben – sonst fiele der Update-Hinweis
    /// aus, sobald sie die Grenzen erreichen (`appcast.swift` fügt mit jedem Release einen Eintrag hinzu).
    @Test(arguments: ["distribution/appcast.xml", "docs/testing/update-testfeed.xml", "docs/testing/update-testfeed-foreign-host.xml"])
    func shippedFeedsStayWithinTheLimits(path: String) throws {
        let url = Self.repositoryRoot.appending(path: path)
        try #require(FileManager.default.fileExists(atPath: url.path), "Repository-Datei fehlt: \(path)")
        let data = try Data(contentsOf: url)
        #expect(data.count < UpdateFeed.maximumFeedBytes / 2)
        let items = try AppcastParser.items(from: data)
        // Weit unter der Grenze: `scripts/appcast.swift` hält den Feed kurz, `UpdateFeed.maximumItems` ist nur die Notbremse.
        #expect(items.count < UpdateFeed.maximumItems / 2)
    }

    @Test func generatorKeepsFarFewerItemsThanTheParserReads() throws {
        let script = try String(contentsOf: Self.repositoryRoot.appending(path: "scripts/appcast.swift"), encoding: .utf8)
        let match = try #require(script.firstMatch(of: /let maximumKeptItems = (\d+)/), "maximumKeptItems fehlt im Skript")
        let kept = try #require(Int(match.1))
        #expect(kept < UpdateFeed.maximumItems / 2)
    }
}
