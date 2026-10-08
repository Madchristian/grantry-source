import Foundation

/// Frische, temporäre Verzeichnisse für Tests, die nach dem Lauf wieder entfernt werden.
public enum ScratchDirectory {
    /// Führt `body` in einem frischen Verzeichnis aus und räumt es anschließend ab.
    public static func with<T>(prefix: String = "scratch", _ body: (URL) throws -> T) throws -> T {
        let directory = try make(prefix: prefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// Asynchrone Variante von `with(prefix:_:)`.
    public static func with<T>(prefix: String = "scratch", _ body: (URL) async throws -> T) async throws -> T {
        let directory = try make(prefix: prefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    /// Wie `with(prefix:_:)`, aber mit symlinkfreiem Pfad (`realpath`, z. B. `/private/var` statt `/var`) – für Code,
    /// der Pfade komponentenweise ohne Symlink-Auflösung öffnet (`BoundDirectory`).
    public static func withCanonical<T>(prefix: String = "scratch", _ body: (URL) throws -> T) throws -> T {
        try with(prefix: prefix) { try body(try canonical($0)) }
    }

    /// Asynchrone Variante von `withCanonical(prefix:_:)`.
    public static func withCanonical<T>(prefix: String = "scratch", _ body: (URL) async throws -> T) async throws -> T {
        try await with(prefix: prefix) { try await body(try canonical($0)) }
    }

    private static func canonical(_ directory: URL) throws -> URL {
        guard let resolved = realpath(directory.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    private static func make(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// ACL-Einträge für Tests (`chmod +a`).
public enum AccessControlFixture {
    public struct Failure: Error, Equatable {
        public let status: Int32
    }

    /// `chmod +a entry path`, etwa `group:staff allow delete_child,add_file`.
    public static func grant(_ entry: String, to path: String) throws {
        let chmod = Process()
        chmod.executableURL = URL(filePath: "/bin/chmod")
        chmod.arguments = ["+a", entry, path]
        try chmod.run()
        chmod.waitUntilExit()
        guard chmod.terminationStatus == 0 else { throw Failure(status: chmod.terminationStatus) }
    }
}

/// Minimales App-Bundle (`Name.app/Contents/Info.plist`) als Fixture.
public enum AppBundleFixture {
    /// Legt `directory/name.app` mit einer Info.plist aus `bundleID` und `bundleName` an.
    @discardableResult
    public static func make(in directory: URL, named name: String, bundleID: String, bundleName: String) throws -> URL {
        let bundle = directory.appending(path: "\(name).app")
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
        try writeInfoPlist(of: bundle, bundleID: bundleID, bundleName: bundleName)
        return bundle
    }

    /// Schreibt die Info.plist von `bundle` (neu).
    public static func writeInfoPlist(of bundle: URL, bundleID: String, bundleName: String) throws {
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": bundleName]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoPlist(of: bundle))
    }

    /// Fester Zeitstempel, damit Tests Änderungsdaten exakt kontrollieren.
    public static let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// Setzt die Änderungsdaten von Info.plist, `Contents` und Bundle-Verzeichnis auf feste Werte.
    public static func pin(_ bundle: URL, plistModified: Date = pinnedDate) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.modificationDate: plistModified], ofItemAtPath: infoPlist(of: bundle).path)
        for directory in [bundle.appending(path: "Contents"), bundle] {
            try fileManager.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: directory.path)
        }
    }

    public static func infoPlist(of bundle: URL) -> URL {
        bundle.appending(path: "Contents/Info.plist")
    }
}

/// Datei in einem Verzeichnis ohne Zugriffsrechte (Modus 000) – bildet root-only-Verzeichnisse wie `/Library/Ossec`
/// aus Sicht eines normalen Benutzers nach.
public enum LockedDirectoryFixture {
    /// Legt `<scratch>/locked/fileName` an, sperrt `locked` für die Dauer von `body` und gibt die Rechte danach
    /// zurück, damit das Aufräumen gelingt.
    public static func with<T>(fileNamed fileName: String, _ body: (URL) async throws -> T) async throws -> T {
        try await ScratchDirectory.with(prefix: "locked") { directory in
            let locked = directory.appending(path: "locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            let file = locked.appending(path: fileName)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            return try await body(file)
        }
    }
}
