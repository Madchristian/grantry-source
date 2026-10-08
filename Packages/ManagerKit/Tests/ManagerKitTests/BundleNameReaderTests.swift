import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Anzeigenamen nur aus Bundle-Dateien in Scratch-Ordnern – Launch Services sieht keines dieser Bundles (Review H2).
@Suite struct BundleNameReaderTests {
    private let german = BundleNameReader(preferredLanguages: { ["de-DE", "en-US"] })

    private func resources(of bundle: URL) throws -> URL {
        let resources = bundle.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        return resources
    }

    private func strings(_ data: Data, in bundle: URL, language: String) throws {
        let folder = try resources(of: bundle).appending(path: "\(language).lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: "InfoPlist.strings"))
    }

    private func name(_ reader: BundleNameReader, _ bundle: URL) -> String {
        reader.name(ofBundleAt: bundle.path, info: BundleLayout(path: bundle.path).info)
    }

    @Test func displayNameBeatsBundleNameBeatsFileName() throws {
        try ScratchDirectory.with(prefix: "names") { directory in
            let both = try AppFixture.make(in: directory, named: "Both", bundleID: "com.example.both",
                                           extra: ["CFBundleDisplayName": "Anzeige", "CFBundleName": "Kurz"])
            #expect(name(german, both) == "Anzeige")
            let short = try AppFixture.make(in: directory, named: "Short", bundleID: "com.example.short", extra: ["CFBundleName": "Kurz"])
            #expect(name(german, short) == "Kurz")
            let none = try AppFixture.make(in: directory, named: "Plain Name", bundleID: "com.example.none", extra: ["CFBundleName": ""])
            #expect(name(german, none) == "Plain Name")
            let suffixed = try AppFixture.make(in: directory, named: "Suffix", bundleID: "com.example.suffix",
                                               extra: ["CFBundleDisplayName": "Mit Endung.app"])
            #expect(name(german, suffixed) == "Mit Endung")
        }
    }

    @Test func localizedTextStringsWin() throws {
        try ScratchDirectory.with(prefix: "names") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Calc", bundleID: "com.example.calc",
                                             extra: ["CFBundleDisplayName": "Calculator"])
            try strings(Data("/* Kommentar */\n\"CFBundleDisplayName\" = \"Rechner\";\n".utf8), in: bundle, language: "de")
            try strings(Data("\"CFBundleDisplayName\" = \"Calculatrice\";".utf8), in: bundle, language: "fr")
            #expect(name(german, bundle) == "Rechner")
            #expect(name(BundleNameReader(preferredLanguages: { ["fr-FR"] }), bundle) == "Calculatrice")
            #expect(name(BundleNameReader(preferredLanguages: { ["ja-JP"] }), bundle) == "Calculator")
        }
    }

    @Test func utf16AndBinaryStringsAreRead() throws {
        try ScratchDirectory.with(prefix: "names") { directory in
            let utf16 = try AppFixture.make(in: directory, named: "Wide", bundleID: "com.example.wide")
            try strings(try #require("\"CFBundleName\" = \"Breit\";".data(using: .utf16)), in: utf16, language: "de")
            #expect(name(german, utf16) == "Breit")

            let binary = try AppFixture.make(in: directory, named: "Binary", bundleID: "com.example.binary")
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": "Binär"], format: .binary, options: 0)
            try strings(data, in: binary, language: "de_DE")
            #expect(name(german, binary) == "Binär")
        }
    }

    @Test func loctableIsRead() throws {
        try ScratchDirectory.with(prefix: "names") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Settings", bundleID: "com.example.settings")
            let table: [String: Any] = ["en": ["CFBundleDisplayName": "System Settings"], "de": ["CFBundleDisplayName": "Systemeinstellungen"]]
            try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
                .write(to: try resources(of: bundle).appending(path: "InfoPlist.loctable"))
            #expect(name(german, bundle) == "Systemeinstellungen")
            #expect(name(BundleNameReader(preferredLanguages: { ["it-IT"] }), bundle) == "System Settings")
        }
    }

    /// Ohne bevorzugte Sprache zählt `CFBundleDevelopmentRegion`, auch unter altem `.lproj`-Namen (`German.lproj`).
    @Test func developmentRegionAndLegacyNamesAreFallbacks() throws {
        try ScratchDirectory.with(prefix: "names") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Old", bundleID: "com.example.old",
                                             extra: ["CFBundleDevelopmentRegion": "de", "CFBundleName": "Old"])
            try strings(Data("\"CFBundleName\" = \"Alt\";".utf8), in: bundle, language: "German")
            #expect(name(BundleNameReader(preferredLanguages: { ["ja-JP"] }), bundle) == "Alt")
        }
    }

    @Test func candidatesCoverRegionScriptAndLegacyNames() {
        #expect(BundleNameReader.candidates(for: ["zh-Hans-CN"]) == ["zh-Hans-CN", "zh_Hans_CN", "zh-Hans", "zh_Hans", "zh"])
        #expect(BundleNameReader.candidates(for: ["de_DE", nil, "de", "en"]) == ["de-DE", "de_DE", "de", "German", "en", "English"])
        #expect(BundleNameReader.candidates(for: ["../evil", "a/b", ""]).isEmpty)
    }

    /// Sonderdateien als Lokalisierung blockieren nicht und gelten nicht; der Name kommt dann aus der Info.plist.
    @Test(arguments: [false, true])
    func fifoLocalizationDoesNotBlock(asLoctable: Bool) async throws {
        try await ScratchDirectory.with(prefix: "names") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Trap", bundleID: "com.example.trap", extra: ["CFBundleName": "Falle"])
            let folder = try asLoctable ? resources(of: bundle) : resources(of: bundle).appending(path: "de.lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fifo = try FIFOFixture.make(in: folder, named: asLoctable ? "InfoPlist.loctable" : "InfoPlist.strings")
            let reader = german
            let path = bundle.path
            #expect(await FIFOFixture.completes(unblocking: fifo) {
                reader.name(ofBundleAt: path, info: BundleLayout(path: path).info)
            } == "Falle")
        }
    }

    @Test func oversizedTableIsIgnored() throws {
        try ScratchDirectory.with(prefix: "names") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Huge", bundleID: "com.example.huge", extra: ["CFBundleName": "Groß"])
            var text = "\"CFBundleName\" = \"Riesig\";\n"
            text += String(repeating: "/* ................................................................ */\n", count: 20_000)
            try strings(Data(text.utf8), in: bundle, language: "de")
            #expect(name(german, bundle) == "Groß")
        }
    }

    /// iOS-App im Wrapper: Lokalisierung aus dem inneren, flachen Bundle.
    @Test func wrappedAppIsLocalizedFromTheInnerBundle() throws {
        try ScratchDirectory.with(prefix: "names") { directory in
            let (outer, inner) = try AppFixture.makeWrapped(in: directory, named: "Tunnel",
                                                            info: ["CFBundleIdentifier": "de.example.tunnel", "CFBundleName": "Tunnel"])
            let folder = inner.appending(path: "de.lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("\"CFBundleName\" = \"Tunnelprüfer\";".utf8).write(to: folder.appending(path: "InfoPlist.strings"))
            #expect(german.name(ofBundleAt: outer.path, info: BundleLayout(path: inner.path).info) == "Tunnelprüfer")
        }
    }
}

/// Review N1: Namen aus Bundles sind fremde Eingaben – Steuer- und Formatzeichen (auch Bidi-Overrides, die „exe.pdf“
/// als „fdp.exe“ zeigen) fallen weg, Leerraum wird zusammengefasst, die Länge begrenzt.
@Suite struct DisplayNameSanitizingTests {
    @Test(arguments: [
        ("Zoom", "Zoom"),
        ("  Zoom \n\t Meeting  ", "Zoom Meeting"),
        ("Rechnung\u{202E}fdp.app", "Rechnungfdp.app"),
        ("A\u{2066}B\u{2069}C\u{200B}D\u{0007}E", "ABCDE"),
        ("Tunnelprüfer 🚀", "Tunnelprüfer 🚀"),
    ])
    func controlAndFormatCharactersAreRemoved(raw: String, expected: String) {
        #expect(BundleNameReader.sanitized(raw) == expected)
    }

    @Test func longNamesAreTruncated() {
        let name = BundleNameReader.sanitized(String(repeating: "x", count: 300))
        #expect(name.count == BundleNameReader.maximumNameLength)
        #expect(name.hasSuffix("…"))
    }

    @Test func namesFromBundleAndFileNameAreSanitized() throws {
        try ScratchDirectory.with(prefix: "names") { directory in
            let reader = BundleNameReader(preferredLanguages: { ["de-DE"] })
            let spoofed = try AppFixture.make(in: directory, named: "Spoof", bundleID: "com.example.spoof",
                                              extra: ["CFBundleDisplayName": "Safe\u{202E}gpj.app"])
            #expect(reader.name(ofBundleAt: spoofed.path, info: BundleLayout(path: spoofed.path).info) == "Safegpj")
            let empty = try AppFixture.make(in: directory, named: "Datei Name", bundleID: "com.example.empty",
                                            extra: ["CFBundleDisplayName": "\u{202E}\u{200B} \n"])
            #expect(reader.name(ofBundleAt: empty.path, info: BundleLayout(path: empty.path).info) == "Datei Name")
            #expect(BundleNameReader.fallbackName(of: "/Applications/Evil\u{202E}  Tool.app") == "Evil Tool")
            #expect(BundleNameReader.fallbackName(of: "/Applications/\u{202E}.app") == "Unbenannte App")
        }
    }
}
