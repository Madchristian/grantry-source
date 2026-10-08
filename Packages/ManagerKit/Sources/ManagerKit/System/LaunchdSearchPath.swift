import Darwin

/// Sucht Programme wie `env` (`execvp`) im `PATH`, den launchd seinen Diensten ohne eigenen `PATH` mitgibt.
///
/// Nicht abgedeckt: ein per `launchctl config user path` gesetzter Standard-PATH (braucht root und einen Neustart) –
/// außerhalb des Bedrohungsmodells wie Programme unter `/usr/libexec`.
enum LaunchdSearchPath {
    /// launchds Standard-PATH (`_PATH_STDPATH`): ausschließlich versiegelte Systemverzeichnisse.
    static let standardDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Pfad der ersten ausführbaren regulären Datei `name` in `directories`; `nil`, wenn keine passt. `stat` öffnet
    /// nichts – FIFOs und Geräte werden nur übersprungen.
    static func executable(named name: String, in directories: [String] = standardDirectories) -> String? {
        directories.lazy.map { $0 + "/" + name }.first { path in
            var info = stat()
            return stat(path, &info) == 0 && FileType.isRegularFile(info) && access(path, X_OK) == 0
        }
    }
}
