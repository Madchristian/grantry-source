import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct AppBundleReaderTests {
    @Test func readsMacBundle() throws {
        try ScratchDirectory.with(prefix: "bundle") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool", version: "2.1",
                                             build: "210", extra: ["CFBundleName": "Beispiel"])
            let info = try #require(AppBundleReader.read(bundleAt: bundle.path))
            #expect(info.bundleID == "com.example.tool")
            #expect(info.name == "Beispiel")
            #expect(info.shortVersion == "2.1")
            #expect(info.buildVersion == "210")
            #expect(info.executablePath == bundle.path + "/Contents/MacOS/Example")
            #expect(info.wrappedBundlePath == nil)
        }
    }

    /// iOS-App im Wrapper (vgl. `/Applications/tunneldebugger.app`): kein `Contents/`, flaches inneres Bundle.
    @Test func readsWrappedIOSApp() throws {
        try ScratchDirectory.with(prefix: "bundle") { directory in
            let (outer, inner) = try AppFixture.makeWrapped(
                in: directory, named: "Tunnel",
                info: ["CFBundleIdentifier": "de.example.tunnel", "CFBundleExecutable": "tunnel", "CFBundleShortVersionString": "1.0"],
                executableName: "tunnel"
            )
            let info = try #require(AppBundleReader.read(bundleAt: outer.path))
            #expect(info.bundleID == "de.example.tunnel")
            #expect(info.shortVersion == "1.0")
            #expect(info.executablePath == inner.path + "/tunnel")
            #expect(info.wrappedBundlePath == inner.path)
        }
    }

    @Test func missingInfoPlistIsNil() throws {
        try ScratchDirectory.with(prefix: "bundle") { directory in
            let bundle = directory.appending(path: "Empty.app/Contents")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            #expect(AppBundleReader.read(bundleAt: directory.appending(path: "Empty.app").path) == nil)
        }
    }

    @Test(arguments: ["../evil", "a/b", "", ".", ".."])
    func executableLeavingTheBundleIsIgnored(name: String) throws {
        try ScratchDirectory.with(prefix: "bundle") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool",
                                             extra: ["CFBundleExecutable": name])
            let info = try #require(AppBundleReader.read(bundleAt: bundle.path))
            #expect(info.executablePath == nil)
        }
    }

    @Test func fifoInfoPlistDoesNotBlock() async throws {
        try await ScratchDirectory.with(prefix: "bundle") { directory in
            let contents = directory.appending(path: "Trap.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let fifo = try FIFOFixture.make(in: contents, named: "Info.plist")
            let path = directory.appending(path: "Trap.app").path
            let result = await FIFOFixture.completes(unblocking: fifo) { AppBundleReader.read(bundleAt: path) == nil }
            #expect(result == true)
        }
    }

    /// Ein FIFO als Hauptprogramm darf weder den Anzeigenamen noch das Lesen blockieren.
    @Test func fifoExecutableDoesNotBlock() async throws {
        try await ScratchDirectory.with(prefix: "bundle") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Trap", bundleID: "com.example.trap", executable: nil)
            let fifo = try FIFOFixture.make(in: bundle.appending(path: "Contents/MacOS"), named: "Trap")
            let result = await FIFOFixture.completes(unblocking: fifo) { AppBundleReader.read(bundleAt: bundle.path)?.bundleID }
            #expect(result == "com.example.trap")
        }
    }

    /// Ohne `CFBundleExecutable` nimmt macOS (wie CFBundle) den Bundle-Namen – etwa
    /// `/Applications/Canon Utilities/CameraSurveyProgram/CameraSurveyProgram.app`. Auch dieses Programm darf keine FIFO
    /// sein, bevor Security.framework oder Launch Services es öffnen.
    @Test func missingExecutableKeyFallsBackToTheBundleName() throws {
        try ScratchDirectory.with(prefix: "bundle") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Example", bundleID: "com.example.tool")
            let plist = AppBundleFixture.infoPlist(of: bundle)
            var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
            info["CFBundleExecutable"] = nil
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
            #expect(AppBundleReader.read(bundleAt: bundle.path)?.executablePath == bundle.path + "/Contents/MacOS/Example")
            #expect(FileType.isSafeToInspect(atPath: bundle.path))

            let executable = bundle.appending(path: "Contents/MacOS/Example")
            try FileManager.default.removeItem(at: executable)
            _ = try FIFOFixture.make(in: executable.deletingLastPathComponent(), named: "Example")
            #expect(!FileType.isSafeToInspect(atPath: bundle.path))
        }
    }

    /// Wrapper-Apps: Der Name kommt aus der inneren Info.plist.
    @Test func wrapperAppNameComesFromTheInnerBundle() throws {
        try ScratchDirectory.with(prefix: "bundle") { directory in
            let (outer, _) = try AppFixture.makeWrapped(
                in: directory, named: "Tunnel",
                info: ["CFBundleIdentifier": "de.example.tunnel", "CFBundleExecutable": "tunnel", "CFBundleDisplayName": "Tunnel Debugger"],
                executableName: "tunnel"
            )
            #expect(AppBundleReader.read(bundleAt: outer.path)?.name == "Tunnel Debugger")
        }
    }

    /// Eine FIFO als Hauptprogramm im inneren Bundle macht den Wrapper ungeprüft – auch für die Signaturprüfung des
    /// äußeren Pfads (Review C1 b/d). Geprüft wird nur per `stat`, Security.framework sieht die FIFO nie.
    @Test func fifoInsideTheWrappedBundleIsNotSafe() async throws {
        try await ScratchDirectory.with(prefix: "bundle") { directory in
            let (outer, inner) = try AppFixture.makeWrapped(
                in: directory, named: "Tunnel", info: ["CFBundleIdentifier": "de.example.tunnel", "CFBundleExecutable": "tunnel"]
            )
            #expect(FileType.isSafeToInspect(atPath: outer.path))
            let fifo = try FIFOFixture.make(in: inner, named: "tunnel")
            #expect(!FileType.isSafeToInspect(atPath: outer.path))
            let path = outer.path
            let info = await FIFOFixture.completes(unblocking: fifo) { AppBundleReader.read(bundleAt: path) }
            #expect(info??.bundleID == "de.example.tunnel")
            let signing = await FIFOFixture.completes(unblocking: fifo) { SecuritySigningInspector().inspect(path: path) }
            #expect(signing == .unknown)
        }
    }

    /// `WrappedBundle` zeigt woanders hin: Auch dieses Ziel muss frei von Sonderdateien sein.
    @Test func wrappedBundleLinkToAnUnsafeBundleIsNotSafe() throws {
        try ScratchDirectory.with(prefix: "bundle") { directory in
            let (outer, _) = try AppFixture.makeWrapped(
                in: directory, named: "Tunnel", info: ["CFBundleIdentifier": "de.example.tunnel", "CFBundleExecutable": "tunnel"]
            )
            let elsewhere = directory.appending(path: "Elsewhere.app")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            _ = try FIFOFixture.make(in: elsewhere, named: "Info.plist")
            let link = outer.appending(path: "WrappedBundle")
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: elsewhere.path)
            #expect(!FileType.isSafeToInspect(atPath: outer.path))
        }
    }

    /// Andere Einträge in `Wrapper/` (`iTunesMetadata.plist`) dürfen ebenfalls keine Sonderdateien sein.
    @Test func fifoMetadataInTheWrapperIsNotSafe() throws {
        try ScratchDirectory.with(prefix: "bundle") { directory in
            let (outer, _) = try AppFixture.makeWrapped(
                in: directory, named: "Tunnel", info: ["CFBundleIdentifier": "de.example.tunnel"]
            )
            _ = try FIFOFixture.make(in: outer.appending(path: "Wrapper"), named: "iTunesMetadata.plist")
            #expect(!FileType.isSafeToInspect(atPath: outer.path))
        }
    }

    /// `_CodeSignature/CodeResources` liest Security.framework bei jeder Prüfung (Review H2): Eine FIFO dort macht das
    /// Bundle ungeprüft, die Signaturprüfung endet ohne Blockieren mit `.unknown`.
    @Test func fifoCodeResourcesIsNotSafe() async throws {
        try await ScratchDirectory.with(prefix: "bundle") { directory in
            let bundle = try AppFixture.make(in: directory, named: "Trap", bundleID: "com.example.trap")
            #expect(FileType.isSafeToInspect(atPath: bundle.path))
            let signature = bundle.appending(path: "Contents/_CodeSignature")
            try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
            let fifo = try FIFOFixture.make(in: signature, named: "CodeResources")
            #expect(!FileType.isSafeToInspect(atPath: bundle.path))
            let path = bundle.path
            let signing = await FIFOFixture.completes(unblocking: fifo) { SecuritySigningInspector().inspect(path: path) }
            #expect(signing == .unknown)
        }
    }
}
