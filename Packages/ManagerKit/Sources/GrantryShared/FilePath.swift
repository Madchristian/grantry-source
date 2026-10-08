import Foundation

/// Pfadvergleiche in GrantryShared.
enum FilePath {
    /// Kanonische Form eines Dateipfads: `.`-/`..`-Komponenten aufgelöst, Symlinks gefolgt (auch `/var` →
    /// `/private/var`). Zwei Pfade bezeichnen dieselbe Datei, wenn ihre kanonischen Formen gleich sind.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
