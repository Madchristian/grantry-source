import Foundation

extension FileFingerprint {
    /// Fingerabdruck von `target` (Symlinks bereits aufgelöst) oder `nil`, wenn seine Attribute nicht lesbar sind.
    /// Bei Bundles zählt das Siegel (`Contents/_CodeSignature/CodeResources`, sonst `Contents/Info.plist`), zusammen mit
    /// der Inode des Bundle-Verzeichnisses; sonst das Ziel selbst.
    init?(of target: String) {
        guard let own = Self.attributes(of: target) else { return nil }
        let sealed = Self.isAppBundle(target)
            ? ["Contents/_CodeSignature/CodeResources", "Contents/Info.plist"].lazy
                .compactMap { Self.attributes(of: "\(target)/\($0)") }.first
            : nil
        let file = sealed ?? own
        self.init(modified: file.modified, fileNumber: own.fileNumber, statusChanged: file.statusChanged, size: file.size)
    }

    /// Fingerabdruck laut `lstat`; `nil`, wenn der Pfad fehlt oder nicht lesbar ist.
    private static func attributes(of path: String) -> FileFingerprint? {
        FileType.linkStatus(of: path).map(FileFingerprint.init(status:))
    }

    /// Ziel von `path` mit aufgelösten Symlinks – der Pfad, dessen Fingerabdruck und Signatur zählen.
    static func target(of path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func isAppBundle(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension == "app"
    }
}

/// Ergebnisse pro Pfad, gültig, solange der `FileFingerprint` des Ziels gleich bleibt. Gedacht als Eigenschaft eines
/// Actors oder hinter einer Sperre.
struct FingerprintCache<Value> {
    private struct Entry {
        let fingerprint: FileFingerprint
        let value: Value
    }

    private var entries: [String: Entry] = [:]

    /// Gespeicherter Wert zu `path`, sofern er zu `fingerprint` gehört.
    func value(for path: String, matching fingerprint: FileFingerprint) -> Value? {
        guard let entry = entries[path], entry.fingerprint == fingerprint else { return nil }
        return entry.value
    }

    mutating func store(_ value: Value, for path: String, fingerprint: FileFingerprint) {
        entries[path] = Entry(fingerprint: fingerprint, value: value)
    }

    mutating func removeValue(for path: String) {
        entries[path] = nil
    }

    /// Behält nur die Einträge zu `paths`.
    mutating func retainValues(for paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }
}
