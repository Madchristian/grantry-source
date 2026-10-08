import Foundation

/// launchd-Plists als Test-Fixtures.
public enum LaunchdPlistFixture {
    /// Schreibt `directory/<name>` (Standard: `<label>.plist`) mit `Label = label` bzw. `payload`
    /// und legt `directory` bei Bedarf an.
    @discardableResult
    public static func write(
        label: String? = nil,
        payload: [String: Any]? = nil,
        named name: String? = nil,
        in directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = payload ?? label.map { ["Label": $0] } ?? [:]
        let url = directory.appending(path: name ?? "\(label ?? "fixture").plist")
        try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(to: url)
        return url
    }
    /// Schreibt `payload` in die bestehende Datei `url` – dasselbe Dateiobjekt (Inode), wie ein Updater, der die Plist
    /// in-place umschreibt. Mit `keepingModificationDate` wird das Änderungsdatum danach zurückgesetzt (`utimes`), wie
    /// es ein Angreifer täte; die ctime ändert sich trotzdem.
    public static func overwriteInPlace(_ url: URL, payload: [String: Any], keepingModificationDate: Bool = false) throws {
        let previous = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
        if keepingModificationDate, let previous {
            try FileManager.default.setAttributes([.modificationDate: previous], ofItemAtPath: url.path)
        }
    }
}
