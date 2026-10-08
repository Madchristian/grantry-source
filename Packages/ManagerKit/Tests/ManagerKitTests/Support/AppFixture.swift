import Foundation

/// App-Bundle als Fixture: `directory/name.app/Contents/{Info.plist, MacOS/<name>}`; das Hauptprogramm ist eine Kopie
/// von `executable` (Standard `/usr/bin/true`: universell, x86_64 + arm64 + arm64e).
enum AppFixture {
    @discardableResult
    static func make(
        in directory: URL, named name: String, bundleID: String?, version: String? = "1.0", build: String? = "1",
        executable: URL? = URL(fileURLWithPath: "/usr/bin/true"), extra: [String: Any] = [:]
    ) throws -> URL {
        let bundle = directory.appending(path: "\(name).app")
        let macOS = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleName": name, "CFBundleExecutable": name, "CFBundlePackageType": "APPL"]
        info["CFBundleIdentifier"] = bundleID
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = build
        info.merge(extra) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        if let executable { try FileManager.default.copyItem(at: executable, to: macOS.appending(path: name)) }
        return bundle
    }

    /// iOS-App im Wrapper (vgl. `/Applications/tunneldebugger.app`): `directory/name.app/Wrapper/name.app` mit flachem
    /// inneren Bundle (`Info.plist`, Hauptprogramm `executableName`), kein `Contents/`.
    /// - Returns: (äußeres, inneres) Bundle.
    @discardableResult
    static func makeWrapped(
        in directory: URL, named name: String, info: [String: Any], executableName: String? = nil
    ) throws -> (outer: URL, inner: URL) {
        let outer = directory.appending(path: "\(name).app")
        let inner = outer.appending(path: "Wrapper/\(name).app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: inner.appending(path: "Info.plist"))
        if let executableName {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: inner.appending(path: executableName))
        }
        try FileManager.default.createSymbolicLink(atPath: outer.appending(path: "WrappedBundle").path,
                                                   withDestinationPath: "Wrapper/\(name).app")
        return (outer, inner)
    }
}
