import Foundation
import Testing
@testable import ManagerKit
import TestSupport

@Suite struct SigningInspectorTests {
    let inspector = SecuritySigningInspector()

    @Test func appleSystemAppIsAppleSigned() {
        let info = inspector.inspect(path: "/System/Applications/Calculator.app")
        #expect(info.kind == .apple)
        #expect(info.isNotarized, "Apple-Systemsoftware gilt als notarisiert")
        #expect(info.teamID == nil)
    }

    @Test func appleBinaryIsAppleSigned() {
        #expect(inspector.inspect(path: "/bin/ls").kind == .apple)
    }

    @Test func unsignedScriptIsUnsigned() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "unsigned-\(UUID()).sh")
        try "#!/bin/sh\necho hi\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(inspector.inspect(path: url.path).kind == .unsigned)
    }

    @Test func missingPathIsUnknown() {
        #expect(inspector.inspect(path: "/does/not/exist.app") == .unknown)
    }

    @Test func plainDirectoryIsUnknown() throws {
        try withScratchDirectory { directory in
            #expect(inspector.inspect(path: directory.path) == .unknown)
        }
    }

    @Test func strippedBinaryIsUnsigned() throws {
        try withScratchDirectory { directory in
            let binary = try Codesign.unsignedBinary(in: directory)
            #expect(inspector.inspect(path: binary.path) == SigningInfo(kind: .unsigned))
        }
    }

    @Test func unsignedBundleIsUnsigned() throws {
        try withScratchDirectory { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Unsigniert", adHoc: false)
            #expect(inspector.inspect(path: bundle.path) == SigningInfo(kind: .unsigned))
        }
    }

    @Test func adHocSignedBinaryIsAdHoc() throws {
        try withScratchDirectory { directory in
            let binary = try Codesign.adHocBinary(in: directory)
            #expect(inspector.inspect(path: binary.path) == SigningInfo(kind: .adHoc))
        }
    }

    @Test func adHocSignedBundleIsAdHoc() throws {
        try withScratchDirectory { directory in
            let bundle = try Codesign.bundle(in: directory, named: "AdHoc", adHoc: true)
            #expect(inspector.inspect(path: bundle.path) == SigningInfo(kind: .adHoc))
        }
    }

    @Test(.enabled(if: InstalledApps.developerID != nil, "Keine Developer-ID-App in /Applications"))
    func developerIDAppMatchesCodesign() throws {
        let app = try #require(InstalledApps.developerID)
        let info = inspector.inspect(path: app.path)
        #expect(info.kind == .developerID, "\(app.path)")
        #expect(info.teamID == app.teamID)
        if app.hasStapledTicket {
            #expect(info.isNotarized, "\(app.path) hat ein angeheftetes Ticket")
        }
        #expect(info.developerName?.isEmpty == false, "\(app.path): Entwicklername aus dem Zertifikat")
        #expect(info.developerName == app.authority.flatMap { SigningInfo.developerName(fromCertificateSummary: $0, teamID: info.teamID) })
    }

    @Test(.enabled(if: InstalledApps.appStore != nil, "Keine App-Store-App in /Applications"))
    func appStoreAppMatchesCodesign() throws {
        let app = try #require(InstalledApps.appStore)
        let info = inspector.inspect(path: app.path)
        #expect(info.kind == .appStore, "\(app.path)")
        #expect(info.teamID == app.teamID)
        #expect(info.isNotarized, "App-Store-Apps gelten als notarisiert")
    }

    @Test(.enabled(if: InstalledApps.development != nil, "Keine Apple-Development-signierte App in /Applications"))
    func developmentAppIsDevelopment() throws {
        let app = try #require(InstalledApps.development)
        let info = inspector.inspect(path: app.path)
        #expect(info.kind == .development, "\(app.path): \(info)")
        #expect(info.teamID == app.teamID)
        #expect(!info.isNotarized, "Entwickler-Builds werden nicht notarisiert")
    }

    /// iOS-Apps laufen auf Apple Silicon als Wrapper-Bundle; äußeres Bundle und innere App sind beide App-Store-signiert.
    @Test(.enabled(if: InstalledApps.iOSAppStore != nil, "Keine iOS-App aus dem App Store in /Applications"))
    func wrappedIOSAppIsAppStore() throws {
        let app = try #require(InstalledApps.iOSAppStore)
        let wrapper = app.path + "/Wrapper"
        let inner = try FileManager.default.contentsOfDirectory(atPath: wrapper)
            .filter { $0.hasSuffix(".app") }
            .map { "\(wrapper)/\($0)" }
        for path in [app.path] + inner {
            let info = inspector.inspect(path: path)
            #expect(info.kind == .appStore, "\(path): \(info)")
            #expect(info.teamID == app.teamID, "\(path)")
            #expect(info.isNotarized, "\(path)")
        }
    }

    /// Große Bundles dürfen nicht vollständig (Ressourcen, Hauptprogramm) geprüft werden – das dauert bei Xcode Minuten.
    @Test func largeAppIsInspectedWithoutDeepValidation() throws {
        let candidates = [
            "/Applications/Xcode.app", "/Applications/Keynote.app", "/Applications/Logic Pro.app",
            "/Applications/Docker.app", "/Applications/Warp.app", "/Applications/Google Chrome.app",
            "/System/Applications/Calculator.app",
        ]
        let path = try #require(candidates.first { FileManager.default.fileExists(atPath: $0) })
        var info = SigningInfo.unknown
        let elapsed = ContinuousClock().measure { info = inspector.inspect(path: path) }
        #expect(elapsed < .seconds(1), "\(path) brauchte \(elapsed)")
        #expect([.apple, .appStore, .developerID].contains(info.kind), "\(path): \(info)")
    }

    private func withScratchDirectory(_ body: (URL) throws -> Void) throws {
        try ScratchDirectory.with(prefix: "signing", body)
    }
}
