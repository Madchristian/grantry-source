import Darwin

extension Presence {
    /// Prüft `path` per `stat` (folgt Symlinks). `missing` nur, wenn das Dateisystem das Fehlen belegt: `ENOENT`
    /// (auch bei ins Leere zeigendem Symlink) oder `ENOTDIR` (ein Pfadbestandteil ist kein Verzeichnis). Jeder andere
    /// Fehler – vor allem `EACCES`/`EPERM` bei root-only-Verzeichnissen – ergibt `unknown`.
    public init(ofItemAt path: String) {
        var info = stat()
        guard stat(path, &info) != 0 else {
            self = .present
            return
        }
        switch errno {
        case ENOENT, ENOTDIR: self = .missing
        default: self = .unknown
        }
    }
}
