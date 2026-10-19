import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct WebKitOriginTests {
    /// Echte Datei aus Safari: oberste Seite und Rahmen `https://paperless.local.cstrube.de`, ohne Port.
    private static let paperless = Data([
        0x05, 0, 0, 0, 1] + Array("https".utf8) + [0x1A, 0, 0, 0, 1] + Array("paperless.local.cstrube.de".utf8) + [0]
        + [0x05, 0, 0, 0, 1] + Array("https".utf8) + [0x1A, 0, 0, 0, 1] + Array("paperless.local.cstrube.de".utf8) + [0])

    private static func string(_ text: String, latin1: Bool = true) -> [UInt8] {
        let count = text.utf16.count
        let length = [UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), 0, 0]
        guard !latin1 else { return length + [1] + Array(text.utf8) }
        return length + [0] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    @Test func parsesRealOriginFile() throws {
        let (top, frame) = try #require(WebKitOrigin.parse(Self.paperless))
        #expect(top == frame)
        #expect(frame.text == "paperless.local.cstrube.de")
    }

    @Test func framesInAnotherSiteNameBothWithPortAndUTF16() throws {
        let top = Self.string("https") + Self.string("example.com") + [0]
        let frame = Self.string("https") + Self.string("bücher.example", latin1: false) + [1, 0xFB, 0x20]
        let (parsedTop, parsedFrame) = try #require(WebKitOrigin.parse(Data(top + frame)))
        #expect(parsedTop.text == "example.com")
        #expect(parsedFrame.text == "bücher.example:8443")
    }

    @Test func malformedDataYieldsNothing() {
        #expect(WebKitOrigin.parse(Data()) == nil)
        #expect(WebKitOrigin.parse(Self.paperless.prefix(30)) == nil)
        #expect(WebKitOrigin.parse(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) == nil)
        #expect(WebKitOrigin.parse(Data(Self.string("https") + Self.string("a.b") + [7])) == nil)
    }

    @Test func titleReadsTheFileAndNamesTheTopSite() throws {
        try ScratchDirectory.withCanonical(prefix: "webkit-origin") { scratch in
            let file = scratch.appending(path: "origin")
            let data = Self.string("https") + Self.string("top.example") + [0] + Self.string("https") + Self.string("frame.example") + [0]
            try Data(data).write(to: file)
            #expect(WebKitOrigin.title(fromFileAt: file.path) == "frame.example (in top.example)")
            #expect(WebKitOrigin.title(fromFileAt: scratch.appending(path: "missing").path) == nil)
        }
    }
}

@Suite struct WebKitWALProviderTests {
    /// Schreibt `bytes` echte Bytes (keine dünn belegte Datei), damit `st_blocks` zählt.
    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func originFile(_ host: String, in folder: URL) throws {
        let part = [UInt8(5), 0, 0, 0, 1] + Array("https".utf8) + [UInt8(host.utf8.count), 0, 0, 0, 1] + Array(host.utf8) + [0]
        try Data(part + part).write(to: folder.appending(path: "origin"))
    }

    private func provider(home: URL, fullDiskAccess: Bool) -> WebKitWALProvider {
        WebKitWALProvider(home: home.path, canReadAppContainers: { fullDiskAccess }, minimumBytes: 100_000, minimumRatio: 100)
    }

    @Test func reportsOnlyOversizedWALFilesWithTheirSite() async throws {
        try await ScratchDirectory.withCanonical(prefix: "webkit-wal") { home in
            let safari = home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/WebKit")
            let site = safari.appending(path: "WebsiteData/Default/h1/h1")
            try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
            try originFile("unifi.ui.com", in: site)
            try write(4096, to: site.appending(path: "LocalStorage/localstorage.sqlite3"))
            try write(1_000_000, to: site.appending(path: "LocalStorage/localstorage.sqlite3-wal"))
            // Zu klein im Verhältnis zur Datenbank:
            let busy = safari.appending(path: "WebsiteDataStore/p/Origins/h2/h2/IndexedDB/x")
            try write(100_000, to: busy.appending(path: "IndexedDB.sqlite3"))
            try write(1_000_000, to: busy.appending(path: "IndexedDB.sqlite3-wal"))
            // Ohne `origin`, im Profil, tief unten (IndexedDB) und eine nicht sandboxte App:
            let profile = safari.appending(path: "WebsiteDataStore/p/Origins/h3/h3/IndexedDB/y")
            try write(500_000, to: profile.appending(path: "IndexedDB.sqlite3-wal"))
            let app = home.appending(path: "Library/WebKit/com.example.App/WebsiteData/LocalStorage")
            try write(300_000, to: app.appending(path: "https_legacy.example_0.localstorage-wal"))

            let report = await provider(home: home, fullDiskAccess: true).scan()
            #expect(report.status == .available && report.unreadablePaths.isEmpty)
            #expect(report.category.risk == .reportOnly)
            #expect(report.items.map(\.title) == ["unifi.ui.com", "Unbekannte Website", "legacy.example"])
            #expect(report.items.allSatisfy { !$0.isSelectable && $0.path?.hasSuffix("-wal") == true })
            #expect(report.items[0].detail == "Safari · Datenbank \(AppTexts.formattedSize(4096))")
            #expect(report.items[2].detail?.hasPrefix("com.example.App · ") == true)
        }
    }

    @Test func withoutFullDiskAccessAppContainersStayUntouched() async throws {
        try await ScratchDirectory.withCanonical(prefix: "webkit-wal") { home in
            let site = home.appending(path: "Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default/h/h")
            try write(1_000_000, to: site.appending(path: "LocalStorage/localstorage.sqlite3-wal"))
            let report = await provider(home: home, fullDiskAccess: false).scan()
            #expect(report.status == .needsFullDiskAccess)
            #expect(report.items.isEmpty)
            #expect(report.unreadablePaths == [home.path + "/Library/Containers"])
        }
    }

    @Test func walksNoDeeperThanTheKnownLayout() async throws {
        try await ScratchDirectory.withCanonical(prefix: "webkit-wal") { home in
            let deep = home.appending(path: "Library/WebKit/app/WebsiteData/1/2/3/4/5/6/7")
            try write(1_000_000, to: deep.appending(path: "too-deep.sqlite3-wal"))
            #expect(await provider(home: home, fullDiskAccess: true).scan().items.isEmpty)
        }
    }
}
