/// Allgemeine Netzwerkwerkzeuge, die auf Anweisung lauschen statt einen eigenen Dienst zu sein: `nc -l 4444` öffnet
/// jeden gewünschten Port, `ssh -L`/`-D`/`-R` baut Tunnel. Wie bei einem Interpreter (`ScriptInterpreter`) sagt die
/// (Apple-)Signatur des Werkzeugs nichts über den Dienst dahinter – „Living off the Land“. Daemons wie `sshd` zählen
/// nicht: Sie sind der Dienst selbst.
public enum NetworkTool {
    /// Programmnamen in Kleinschreibung (APFS unterscheidet standardmäßig nicht).
    private static let names: Set<String> = ["nc", "ssh"]

    /// `true`, wenn der letzte Pfadbestandteil von `executable` ein bekanntes Netzwerkwerkzeug ist (`/usr/bin/nc`).
    public static func matches(_ executable: String) -> Bool {
        names.contains(String(executable.split(separator: "/").last ?? "").lowercased())
    }
}
