import Foundation

/// Steam-Bibliotheken außerhalb des Standardordners (#257), gelesen aus Steams `libraryfolders.vdf`
/// (`steamapps/` und `config/`). Den Standardordner nimmt Steam selbst aus Time Machine aus.
enum SteamLibraries {
    /// Bibliotheksordner aus beiden Listen, ohne den Standardordner `steamRoot` und darin liegende, in Lesereihenfolge
    /// und ohne Dubletten; leer, wenn keine Liste lesbar ist.
    static func additional(steamRoot: String) -> [String] {
        let root = (steamRoot as NSString).standardizingPath
        var seen: Set<String> = []
        return ["steamapps", "config"]
            .compactMap { try? String(contentsOfFile: root + "/\($0)/libraryfolders.vdf", encoding: .utf8) }
            .flatMap(paths(in:))
            .filter { $0 != root && !$0.hasPrefix(root + "/") && seen.insert($0).inserted }
    }

    /// Absolute Werte der Schlüssel `"path"` (VDF-Escapes `\\` und `\"` aufgelöst), standardisiert; relative übergangen.
    static func paths(in vdf: String) -> [String] {
        vdf.matches(of: #/"path"\s*"((?:[^"\\]|\\.)*)"/#).compactMap { match in
            let path = String(match.1).replacing(#/\\(.)/#) { String($0.1) }
            return path.hasPrefix("/") ? (path as NSString).standardizingPath : nil
        }
    }
}
