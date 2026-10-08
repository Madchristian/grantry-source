import Foundation

/// Ob und aus welcher Plist ein launchd-Dienst geladen ist – ausgewertet aus `launchctl print <domain>/<label>`.
///
/// launchd führt die Dienste einer Domain nach Label: Zwei Plists mit demselben Label – etwa ein als
/// `com.apple.Dock.agent` getarnter Benutzer-Agent und der echte Apple-Dienst, oder eine Kopie von `org.cups.cupsd`
/// in `/Library/LaunchDaemons` neben Apples Original – teilen sich `<domain>/<label>`. Labelgebundene Befehle
/// (`enable`, `disable`, `bootout <domain>/<label>`) und ein nur am Label abgelesener Ladezustand träfen dann den
/// geladenen, womöglich fremden Dienst. App (`gui/<uid>`) und Helper (`system`, maßgeblich) prüfen deshalb vor
/// jeder Aktion mit dieser Zuordnung, ob unter dem Label genau die eigene Plist geladen ist.
public enum LaunchdServiceBinding: Equatable, Sendable {
    /// Kein Dienst mit diesem Label geladen.
    case notLoaded
    /// Der geladene Dienst stammt aus genau dieser Plist.
    case loadedFromPlist
    /// Ein Dienst mit diesem Label ist geladen – aus einer anderen oder keiner erkennbaren Plist.
    case loadedFromElsewhere

    /// Exit-Code von `launchctl print`, wenn die Domain keinen Dienst mit diesem Label kennt.
    public static let serviceNotFoundExitCode: Int32 = 113

    /// Argumente für `launchctl`, die den Dienst `label` in `domain` abfragen.
    public static func printArguments(domain: String, label: String) -> [String] {
        ["print", "\(domain)/\(label)"]
    }

    /// Zuordnung des Dienstes aus dem Ergebnis von `launchctl print <domain>/<label>` zur Plist `plistPath`. Pfade
    /// werden nach Auflösen von Symlinks verglichen; ein geladener Dienst ohne `path` gilt als fremd.
    ///
    /// - Returns: `nil`, wenn der Aufruf gescheitert ist (Exit-Code weder 0 noch `serviceNotFoundExitCode`) – der
    ///   Zustand ist dann unbekannt, und der Aufrufer darf nichts verändern.
    public init?(printResult result: CommandResult, plistPath: String) {
        if result.exitCode == Self.serviceNotFoundExitCode {
            self = .notLoaded
            return
        }
        guard result.succeeded else { return nil }
        guard let loadedPath = Self.servicePlistPath(in: result.stdout),
              FilePath.canonical(loadedPath) == FilePath.canonical(plistPath) else {
            self = .loadedFromElsewhere
            return
        }
        self = .loadedFromPlist
    }

    /// `launchctl print <domain>/<label>` → Plist-Pfad des Dienstes (`path = …`), `nil` ohne Pfad.
    ///
    /// Gilt nur die erste Zeile auf oberster Ebene des Dienstblocks (genau ein Tab eingerückt): Verschachtelte Blöcke
    /// wie Argumente oder Umgebung enthalten frei wählbare Texte, und der echte Pfad steht vor ihnen. Ein Dienst
    /// könnte eine solche Zeile höchstens über einen Zeilenumbruch in einem seiner Strings vortäuschen – und damit
    /// nur Aktionen auf sich selbst lenken, den er ohnehin schon in die Domain gebracht hat.
    public static func servicePlistPath(in output: String) -> String? {
        let prefix = "\tpath = "
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }
}
