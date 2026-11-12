import Foundation
import Testing
@testable import ManagerKit

/// Drittanbieter-Lizenzen (#519): Verzeichnis und Lizenztexte aus dem App-Paket; Fehlendes wird gemeldet, nie leer gezeigt.
@Suite struct ThirdPartyNoticesTests {
    private static let manifest = Data("""
        [{"name": "Sparkle", "version": "2.10.0", "revision": "eef1a539a373c1f1a320624b1130fc5de7b2e100",
          "projectURL": "https://github.com/sparkle-project/Sparkle", "licenseFile": "Sparkle-LICENSE.txt"}]
        """.utf8)

    @Test func loadsEachNoticeWithItsLicenseText() throws {
        let licenses = try ThirdPartyNotices.load(manifest: Self.manifest) { file in
            #expect(file == "Sparkle-LICENSE.txt")
            return "Copyright (c) Sparkle"
        }
        let sparkle = try #require(licenses.first)
        #expect(licenses.count == 1)
        #expect(sparkle.notice.name == "Sparkle")
        #expect(sparkle.notice.version == "2.10.0")
        #expect(sparkle.notice.projectURL == URL(string: "https://github.com/sparkle-project/Sparkle"))
        #expect(sparkle.text == "Copyright (c) Sparkle")
        #expect(sparkle.id == "Sparkle")
    }

    @Test func rejectsAnEmptyLicenseText() {
        #expect(throws: ThirdPartyNotices.LoadError.missingLicense("Sparkle-LICENSE.txt")) {
            try ThirdPartyNotices.load(manifest: Self.manifest) { _ in " \n" }
        }
    }

    @Test func rejectsAnEmptyManifest() {
        #expect(throws: ThirdPartyNotices.LoadError.emptyManifest) {
            try ThirdPartyNotices.load(manifest: Data("[]".utf8)) { _ in "text" }
        }
    }

    @Test func rejectsLicenseFilesOutsideTheResources() {
        let escaping = Data("""
            [{"name": "X", "version": "1", "revision": "r", "projectURL": "https://example.com",
              "licenseFile": "../X-LICENSE.txt"}]
            """.utf8)
        #expect(throws: ThirdPartyNotices.LoadError.missingLicense("../X-LICENSE.txt")) {
            try ThirdPartyNotices.load(manifest: escaping) { _ in "text" }
        }
    }

    @Test func readsManifestAndLicensesFromABundleDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.manifest.write(to: directory.appending(path: "ThirdPartyNotices.json"))
        try Data("MIT License".utf8).write(to: directory.appending(path: "Sparkle-LICENSE.txt"))

        let licenses = try ThirdPartyNotices.load(fromResources: directory)

        #expect(licenses.map(\.text) == ["MIT License"])
    }

    /// Das ausgelieferte Verzeichnis aus Grantry/Licenses lässt sich laden und enthält Sparkle mit Lizenztext.
    @Test func loadsTheShippedNotices() throws {
        let resources = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../Grantry/Licenses").standardized
        let licenses = try ThirdPartyNotices.load(fromResources: resources)
        let sparkle = try #require(licenses.first { $0.notice.name == "Sparkle" })
        #expect(sparkle.text.hasPrefix("Copyright (c) 2006-2013 Andy Matuschak."))
        #expect(sparkle.text.contains("SUSignatureVerifier.m"))
    }

    @Test func reportsAMissingManifest() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(throws: ThirdPartyNotices.LoadError.missingManifest) {
            try ThirdPartyNotices.load(fromResources: directory)
        }
    }
}
