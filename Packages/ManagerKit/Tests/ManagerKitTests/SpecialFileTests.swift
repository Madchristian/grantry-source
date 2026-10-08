import Foundation
import Synchronization
import Testing
@testable import ManagerKit
import TestSupport

/// FIFOs, Sockets und Geräte als Programm eines Autostart-Eintrags: Weder Shebang-Lesen noch Signaturprüfung dürfen an
/// ihnen hängen – ein Angreifer könnte sonst jeden Scan anhalten.
@Suite struct SpecialFileTests {
    @Test func shebangOfFIFOIsNil() async throws {
        try await ScratchDirectory.with(prefix: "fifo") { directory in
            let fifo = try FIFOFixture.make(in: directory)
            let shebang = await FIFOFixture.completes(unblocking: fifo) { ScriptFile.shebang(atPath: fifo.path) }
            #expect(shebang == .some(nil))
        }
    }

    @Test func signingOfFIFOIsUnknown() async throws {
        try await ScratchDirectory.with(prefix: "fifo") { directory in
            let fifo = try FIFOFixture.make(in: directory)
            let direct = await FIFOFixture.completes(unblocking: fifo) { SecuritySigningInspector().inspect(path: fifo.path) }
            #expect(direct == .unknown)
            let cached = await FIFOFixture.completes(unblocking: fifo) { CachingSigningInspector().inspect(path: fifo.path) }
            #expect(cached == .unknown)
        }
    }

    @Test func deepValidationOfFIFOIsUnverifiable() async throws {
        try await ScratchDirectory.with(prefix: "fifo") { directory in
            let fifo = try FIFOFixture.make(in: directory)
            let verdict = await FIFOFixture.completes(unblocking: fifo) { SecuritySignatureValidator().validate(path: fifo.path) }
            #expect(verdict == .unverifiable)
        }
    }

    /// Auch über einen Symlink: geprüft wird das Ziel.
    @Test func symlinkToFIFOIsUnknown() async throws {
        try await ScratchDirectory.with(prefix: "fifo") { directory in
            let fifo = try FIFOFixture.make(in: directory)
            let link = directory.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
            let signing = await FIFOFixture.completes(unblocking: fifo) { SecuritySigningInspector().inspect(path: link.path) }
            #expect(signing == .unknown)
            let shebang = await FIFOFixture.completes(unblocking: fifo) { ScriptFile.shebang(atPath: link.path) }
            #expect(shebang == .some(nil))
        }
    }

    /// App-Bundle `Evil.app` mit regulärer Info.plist; das Hauptprogramm `Contents/MacOS/Evil` liefert `makeExecutable`.
    private func bundle(in directory: URL, infoPlistIsFIFO: Bool = false) throws -> (bundle: URL, fifo: URL) {
        let bundle = directory.appending(path: "Evil.app")
        let contents = bundle.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.evil", "CFBundleExecutable": "Evil"], format: .xml, options: 0
        )
        if infoPlistIsFIFO {
            try FileManager.default.copyItem(atPath: "/bin/ls", toPath: macOS.appending(path: "Evil").path)
            return (bundle, try FIFOFixture.make(in: contents, named: "Info.plist"))
        }
        try info.write(to: contents.appending(path: "Info.plist"))
        return (bundle, try FIFOFixture.make(in: macOS, named: "Evil"))
    }

    /// Eine FIFO als Hauptprogramm oder Info.plist eines Bundles hält weder Signaturprüfung noch Tiefenprüfung an.
    @Test(arguments: [false, true])
    func fifoInsideBundleDoesNotBlockSigning(infoPlistIsFIFO: Bool) async throws {
        try await ScratchDirectory.with(prefix: "fifo-bundle") { directory in
            let (bundle, fifo) = try bundle(in: directory, infoPlistIsFIFO: infoPlistIsFIFO)
            let signing = await FIFOFixture.completes(unblocking: fifo) { SecuritySigningInspector().inspect(path: bundle.path) }
            #expect(signing == .unknown)
            let verdict = await FIFOFixture.completes(unblocking: fifo) { SecuritySignatureValidator().validate(path: bundle.path) }
            #expect(verdict == .containsSpecialFiles)
        }
    }

    /// Eine FIFO irgendwo im Bundle (hier unter `Contents/Resources`) hält die Tiefenprüfung nicht an: Vor
    /// `SecStaticCodeCheckValidity` durchsucht der Validator den Baum per `lstat` und meldet „enthält Sonderdateien“.
    @Test func fifoDeepInsideBundleIsReportedBeforeDeepValidation() async throws {
        try await ScratchDirectory.with(prefix: "fifo-bundle") { directory in
            let bundle = try Codesign.bundle(in: directory, named: "Tief", adHoc: true, resources: ["config.txt": "x"])
            let fifo = try FIFOFixture.make(in: bundle.appending(path: "Contents/Resources"), named: "pipe")
            let verdict = await FIFOFixture.completes(unblocking: fifo) { SecuritySignatureValidator().validate(path: bundle.path) }
            #expect(verdict == .containsSpecialFiles)
        }
    }

    /// Erkannt werden FIFOs im Baum, auch als Ziel eines Symlinks im Bundle; reguläre Dateien, Ordner und Symlinks
    /// auf solche nicht.
    @Test func specialFilesInATreeAreFound() throws {
        try ScratchDirectory.with(prefix: "special-tree") { directory in
            let tree = directory.appending(path: "Baum")
            try FileManager.default.createDirectory(at: tree.appending(path: "a/b"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: tree.appending(path: "a/b/datei"))
            try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "a/link").path, withDestinationPath: "b/datei")
            #expect(FileType.specialFiles(inTreeAt: tree.path) == .clean)

            let fifo = try FIFOFixture.make(in: directory, named: "aussen")
            try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "a/zur-fifo").path, withDestinationPath: fifo.path)
            #expect(FileType.specialFiles(inTreeAt: tree.path) == .found)
            try FileManager.default.removeItem(at: tree.appending(path: "a/zur-fifo"))
            #expect(FileType.specialFiles(inTreeAt: tree.path) == .clean)

            _ = try FIFOFixture.make(in: tree.appending(path: "a/b"), named: "innen")
            #expect(FileType.specialFiles(inTreeAt: tree.path) == .found)
        }
    }

    /// Review N5: `stat` auf Symlink-Ziele ist begrenzt (Anzahl und Zeit). Ist die Grenze erreicht, bleibt der Baum
    /// ungeprüft (`incomplete`) – die Tiefenprüfung zählt das wie eine Zeitüberschreitung.
    @Test func symlinkTargetChecksAreLimited() throws {
        try ScratchDirectory.with(prefix: "special-tree") { directory in
            let tree = directory.appending(path: "Baum")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: tree.appending(path: "datei"))
            for index in 0..<3 {
                try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "link-\(index)").path,
                                                           withDestinationPath: "datei")
            }
            #expect(FileType.specialFiles(inTreeAt: tree.path) == .clean)
            #expect(FileType.specialFiles(inTreeAt: tree.path, limits: .init(maximumLinkChecks: 3, deadline: .seconds(60))) == .clean)
            #expect(FileType.specialFiles(inTreeAt: tree.path, limits: .init(maximumLinkChecks: 2, deadline: .seconds(60)))
                    == .incomplete)
            #expect(FileType.specialFiles(inTreeAt: tree.path, limits: .init(maximumLinkChecks: 100, deadline: .zero))
                    == .incomplete)
            let validation = SecuritySignatureValidator.validationWithoutTimeLimit(
                path: tree.path, limits: .init(maximumLinkChecks: 2, deadline: .seconds(60))
            )
            #expect(validation == .timedOut)
        }
    }

    /// FIFO, Socket und Geräte zählen als Sonderdatei, Dateien, Ordner und Symlinks nicht.
    @Test func specialFileModes() {
        for mode in [S_IFIFO, S_IFSOCK, S_IFCHR, S_IFBLK] { #expect(FileType.isSpecialFile(mode: mode), "\(mode)") }
        for mode in [S_IFREG, S_IFDIR, S_IFLNK] { #expect(!FileType.isSpecialFile(mode: mode), "\(mode)") }
    }

    /// Auch der App-Resolver (Info.plist, Anzeigename, Signatur) bleibt nicht an einer FIFO im Bundle hängen.
    @Test(arguments: [false, true])
    func fifoInsideBundleDoesNotBlockTheResolver(infoPlistIsFIFO: Bool) async throws {
        try await ScratchDirectory.with(prefix: "fifo-bundle") { directory in
            let (bundle, fifo) = try bundle(in: directory, infoPlistIsFIFO: infoPlistIsFIFO)
            let resolver = AppResolver()
            let identity = await FIFOFixture.completes(unblocking: fifo) { await resolver.resolve(path: bundle.path) }
            #expect(identity?.signing == .unknown)
            #expect(identity?.displayName == "Evil")
        }
    }
}
