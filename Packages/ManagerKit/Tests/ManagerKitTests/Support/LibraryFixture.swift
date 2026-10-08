import Foundation
import TestSupport
@testable import ManagerKit

/// Nachgebautes System für Reste-Tests: `<scratch>/root` (Systemwurzel) und `<scratch>/home` (Benutzerordner), mit
/// leeren Reste-Orten und einigen Sperrorten.
struct LibraryFixture {
    let layout: LibraryLayout

    var home: String { layout.home }
    var root: String { layout.systemRoot }

    static func with<T>(_ body: (LibraryFixture) async throws -> T) async throws -> T {
        try await ScratchDirectory.with(prefix: "library") { directory in
            let fileManager = FileManager.default
            let root = directory.appending(path: "root"), home = directory.appending(path: "home")
            for path in ["Applications", "Library/Application Support", "Library/Caches", "Library/Preferences",
                         "Library/Apple", "System/Library", "usr/bin", "private/etc"] {
                try fileManager.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
            }
            for path in ["Applications", "Documents", "Library/Containers", "Library/Group Containers",
                         "Library/Application Support", "Library/Caches", "Library/Preferences/ByHost",
                         "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Logs",
                         "Library/Application Scripts", "Library/Keychains", "Library/Mobile Documents", "Library/Mail",
                         "Library/Messages", "Library/Photos", "Library/CloudStorage"] {
                try fileManager.createDirectory(at: home.appending(path: path), withIntermediateDirectories: true)
            }
            return try await body(LibraryFixture(layout: LibraryLayout(home: home.path, systemRoot: root.path)))
        }
    }

    func userLibrary(_ relative: String) -> String { home + "/Library/" + relative }
    func system(_ relative: String) -> String { root + "/" + relative }

    /// Legt einen Ordner mit einer Datei (`bytes` groß) an.
    @discardableResult
    func folder(_ path: String, bytes: Int = 1_024) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path).appending(path: "data"))
        return path
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 1_024) throws -> String {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Ersetzt den Eintrag `path` durch einen Symlink auf `destination`.
    func replaceWithSymlink(_ path: String, to destination: String) throws {
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    /// App-Bundle in `<root>/Applications/<subfolder>`.
    @discardableResult
    func app(_ name: String, bundleID: String?, subfolder: String = "") throws -> String {
        let folder = URL(fileURLWithPath: system("Applications")).appending(path: subfolder)
        return try AppFixture.make(in: folder, named: name, bundleID: bundleID).path
    }

    /// Komponenten-Bundle ohne `.app` (`Foo.prefPane`, `Bar.driver`) in `directory`, mit `Contents/Info.plist`.
    @discardableResult
    func component(_ name: String, bundleID: String, in directory: String) throws -> String {
        let bundle = directory + "/" + name
        try FileManager.default.createDirectory(atPath: bundle + "/Contents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        return bundle
    }
}
