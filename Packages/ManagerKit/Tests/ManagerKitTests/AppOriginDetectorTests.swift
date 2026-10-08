import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AppOriginDetectorTests {
    private let developer = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)

    private func receipt(in bundle: URL) throws {
        let folder = bundle.appending(path: "Contents/_MASReceipt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x30, 0x82, 0x13, 0x12]).write(to: folder.appending(path: "receipt"))
    }

    private func origin(_ bundle: URL, signing: SigningInfo, casks: HomebrewCaskIndex = .empty) throws -> AppOrigin {
        let info = try #require(AppBundleReader.read(bundleAt: bundle.path))
        return AppOriginDetector.origin(ofBundleAt: bundle.path, info: info, signing: signing, casks: casks)
    }

    @Test func homebrewWinsOverAppStoreReceipt() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Tool", bundleID: "com.example.tool")
            try receipt(in: bundle)
            let casks = HomebrewCaskIndex(casksByPath: [bundle.path: "tool"])
            #expect(try origin(bundle, signing: SigningInfo(kind: .appStore, isNotarized: true), casks: casks) == .homebrew(cask: "tool"))
        }
    }

    /// Review N3: Ein Beleg lässt sich in jedes Bundle legen – er zählt nur mit App-Store- bzw. Apple-Signatur.
    @Test func receiptCountsOnlyWithAppStoreOrAppleSigning() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Bitwarden", bundleID: "com.bitwarden.desktop")
            try receipt(in: bundle)
            #expect(try origin(bundle, signing: SigningInfo(kind: .appStore, teamID: "LTZ2PFU5D6", isNotarized: true)) == .appStore)
            #expect(try origin(bundle, signing: developer) == .direct)
            #expect(try origin(bundle, signing: SigningInfo(kind: .adHoc)) == .direct)
            #expect(try origin(bundle, signing: SigningInfo(kind: .unsigned)) == .direct)
            #expect(try origin(bundle, signing: .unknown) == .unverified)
        }
    }

    @Test func receiptSymlinkIsNoEvidence() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Tool", bundleID: "com.example.tool")
            let folder = bundle.appending(path: "Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "receipt").path, withDestinationPath: "/etc/hosts")
            #expect(try origin(bundle, signing: SigningInfo(kind: .apple, isNotarized: true)) == .apple)
        }
    }

    @Test func fifoReceiptIsNoEvidenceWithoutBlocking() async throws {
        try await ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Tool", bundleID: "com.example.tool")
            let folder = bundle.appending(path: "Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fifo = try FIFOFixture.make(in: folder, named: "receipt")
            let info = try #require(AppBundleReader.read(bundleAt: bundle.path))
            let result = await FIFOFixture.completes(unblocking: fifo) {
                AppOriginDetector.origin(ofBundleAt: bundle.path, info: info, signing: SigningInfo(kind: .apple, isNotarized: true),
                                         casks: .empty)
            }
            #expect(result == .apple)
        }
    }

    @Test func signingDecidesWithoutReceipt() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Tool", bundleID: "com.example.tool")
            #expect(try origin(bundle, signing: SigningInfo(kind: .appStore, isNotarized: true)) == .appStore)
            #expect(try origin(bundle, signing: SigningInfo(kind: .apple, isNotarized: true)) == .apple)
            #expect(try origin(bundle, signing: developer) == .direct)
            #expect(try origin(bundle, signing: SigningInfo(kind: .adHoc)) == .direct)
        }
    }

    @Test func wrappedAppWithITunesMetadataIsAppStore() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let (outer, _) = try AppFixture.makeWrapped(in: directory, named: "Tunnel", info: ["CFBundleIdentifier": "de.example.tunnel"])
            try Data("<plist/>".utf8).write(to: outer.appending(path: "Wrapper/iTunesMetadata.plist"))
            #expect(try origin(outer, signing: SigningInfo(kind: .appStore, isNotarized: true)) == .appStore)
            #expect(try origin(outer, signing: SigningInfo(kind: .apple, isNotarized: true)) == .appStore)
            #expect(try origin(outer, signing: SigningInfo(kind: .adHoc)) == .direct, "Beleg ohne Store-Signatur zählt nicht")
            #expect(try origin(outer, signing: SigningInfo(kind: .unknown)) == .unverified)
        }
    }

    @Test func wrappedAppWithoutEvidenceIsDirectOrUnverified() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let (outer, _) = try AppFixture.makeWrapped(in: directory, named: "Tunnel", info: ["CFBundleIdentifier": "de.example.tunnel"])
            #expect(try origin(outer, signing: developer) == .direct)
            #expect(try origin(outer, signing: SigningInfo(kind: .unknown)) == .unverified)
        }
    }

    /// Wie `~/Applications/Homelab.app` aus „Zum Dock hinzufügen“: Vorlagen-App ohne `Contents/MacOS`.
    private func safariWebApp(in directory: URL, executable: Bool = false) throws -> URL {
        let template: [String: Any] = [
            "LSTemplateApplication": true,
            "LSTemplateApplicationParameters": ["CFBundleIdentifier": "com.apple.Safari.WebApp", "teamIdentifier": "0000000000"],
        ]
        let bundle = try AppFixture.make(in: directory, named: "Homelab", bundleID: "com.apple.Safari.WebApp.6E59019D",
                                         executable: executable ? URL(fileURLWithPath: "/usr/bin/true") : nil, extra: template)
        if !executable { try FileManager.default.removeItem(at: bundle.appending(path: "Contents/MacOS")) }
        return bundle
    }

    @Test func safariWebAppWithoutProgramIsWebApp() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try safariWebApp(in: directory)
            #expect(try origin(bundle, signing: SigningInfo(kind: .adHoc)) == .webApp(browser: .safari))
            #expect(try origin(bundle, signing: SigningInfo(kind: .unsigned)) == .webApp(browser: .safari))
            #expect(try origin(bundle, signing: developer) == .direct, "signiert gilt die Signatur")
            #expect(try origin(bundle, signing: .unknown) == .unverified)
        }
    }

    /// Mit eigenem Programm ist die Vorlagen-Kennung nur eine Behauptung: Das Bundle bleibt „direkt“ (und ad hoc mittel).
    @Test func safariTemplateWithProgramIsDirect() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try safariWebApp(in: directory, executable: true)
            #expect(try origin(bundle, signing: SigningInfo(kind: .adHoc)) == .direct)
        }
    }

    @Test(arguments: [
        ("com.google.Chrome.app.agimnkijcaahngcdmfeangaknmldooml", WebAppBrowser.chrome),
        ("com.microsoft.edgemac.app.abc", .edge),
        ("com.brave.Browser.app.abc", .brave),
    ])
    func chromiumShimIsWebApp(bundleID: String, browser: WebAppBrowser) throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Shim", bundleID: bundleID)
            #expect(try origin(bundle, signing: SigningInfo(kind: .adHoc)) == .webApp(browser: browser))
        }
    }

    @Test func chromiumPrefixAloneIsNoWebApp() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Shim", bundleID: "com.google.Chrome.app.")
            #expect(try origin(bundle, signing: SigningInfo(kind: .adHoc)) == .direct)
        }
    }

    /// Apple-Apps aus dem App Store (Keynote, Xcode) sind mit `anchor apple` signiert und haben einen Beleg.
    @Test func appleSignedAppWithReceiptIsAppStore() throws {
        try ScratchDirectory.with(prefix: "origin") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Keynote", bundleID: "com.apple.iWork.Keynote")
            try receipt(in: bundle)
            #expect(try origin(bundle, signing: SigningInfo(kind: .apple, isNotarized: true)) == .appStore)
        }
    }

    /// Ohne Signaturergebnis wird „Apple“ nicht aus dem Ort geraten (Review M2, nimmt d5192de zurück): auch nicht im
    /// System oder bei einem Xcode-ähnlichen Namen in `/Applications`. Die Herkunft ist „nicht prüfbar“; der Scan schreibt
    /// die letzte bekannte fort. Nur `lstat` an den Pfaden, kein Lesen, kein Launch Services.
    @Test(arguments: ["/System/Applications/Calculator.app", "/Applications/Xcode-helper.app"])
    func unknownSigningIsUnverifiedEvenOnApplePaths(path: String) {
        let info = AppBundleInfo(bundleID: "com.apple.calculator", name: "Rechner", shortVersion: nil, buildVersion: nil,
                                 executablePath: nil, wrappedBundlePath: nil)
        let origin = AppOriginDetector.origin(ofBundleAt: path, info: info, signing: .unknown, casks: .empty)
        #expect(origin == .unverified)
    }
}
