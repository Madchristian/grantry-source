/// Programme, die fremden Code ausführen, statt selbst der Autostart-Code zu sein: Shells, Skriptsprachen,
/// `osascript`, `env` und `curl` (lädt Code nach). Als Programm eines launchd-Eintrags sagt ihre (Apple-)Signatur
/// nichts über den tatsächlich ausgeführten Code – „Living off the Land“-Tarnung.
public enum ScriptInterpreter {
    /// Programmnamen in Kleinschreibung (APFS unterscheidet standardmäßig nicht); `python`/`perl` auch mit Version.
    private static let names: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish",
        "osascript", "ruby", "php", "node", "tclsh", "swift", "env", "curl",
    ]

    /// `true`, wenn der letzte Pfadbestandteil von `executable` ein bekannter Interpreter ist (`/bin/sh`, `zsh`,
    /// `/opt/homebrew/bin/python3.12`).
    public static func matches(_ executable: String) -> Bool {
        let name = String(executable.split(separator: "/").last ?? "").lowercased()
        return names.contains(name) || name.wholeMatch(of: /(python|perl)[0-9.]*/) != nil
    }
}
