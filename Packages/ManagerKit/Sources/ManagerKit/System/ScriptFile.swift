import Darwin
import Foundation

/// Erste Zeile eines Skripts: `#!<interpreter> [argumente]`. Der Kernel startet die Datei über `interpreter`.
struct Shebang: Equatable, Sendable {
    /// Pfad hinter `#!` (führender Leerraum zählt nicht); leer, wenn die Zeile keinen nennt.
    let interpreter: String
    /// Übrige, an Leerraum getrennte Bestandteile der Zeile.
    let arguments: [String]

    /// `env` des Systems; nur dessen Verhalten ist bekannt.
    static let systemEnv = "/usr/bin/env"

    /// Programm, das `env` über `PATH` sucht – nur in der eindeutigen Form `#!/usr/bin/env <name>`. macOS teilt die
    /// Shebang-Argumente an Leerzeichen; jede weitere Angabe kann die Suche verändern (`-S`, `-P <pfad>`, `-u PATH`,
    /// `PATH=…`) und ergibt `nil`, ebenso ein Pfad (`/`) statt eines Namens.
    var envProgram: String? {
        guard interpreter == Self.systemEnv, arguments.count == 1, let name = arguments.first,
              !name.hasPrefix("-"), !name.contains("="), !name.contains("/") else { return nil }
        return name
    }

    /// `true`, wenn `interpreter` ein `env` ist (letzter Pfadbestandteil).
    static func isEnvPath(_ interpreter: String) -> Bool {
        interpreter.split(separator: "/").last == "env"
    }
}

/// Erkennt Skripte am Shebang: Eine Datei, die mit `#!` beginnt, führt der Kernel über den genannten Interpreter aus.
/// Skripte tragen meist keine eigene Code-Signatur – maßgeblich ist, welcher Interpreter sie ausführt.
///
/// Gelesen wird wie in XNU (`exec_shell_imgact`): höchstens `maximumHeadLength` Bytes; die Zeile endet am ersten `\n`
/// oder `#` (Kommentar), getrennt wird nur an Leerzeichen und Tabulator. `\r` gehört zum Pfad – eine CRLF-Datei nennt
/// `/bin/sh\r`, den der Kernel ebenso wenig findet (die Datei startet nicht; die Bewertung sieht einen fehlenden
/// Interpreter, also **mittel**). Ohne Zeilenende in diesen Bytes verweigert der Kernel die Ausführung (`ENOEXEC`); das
/// ergibt einen leeren Interpreter.
///
/// Gelesen werden nur reguläre Dateien (`FileType.contentsOfRegularFile`): Eine FIFO, ein Socket oder ein Gerät als
/// Programmpfad kann beim Öffnen oder Lesen blockieren und hielte sonst den Scan an.
enum ScriptFile {
    /// Höchstzahl gelesener Bytes samt `#!` – wie `IMG_SHSIZE` in XNU.
    static let maximumHeadLength = 512
    private static let marker = Data("#!".utf8)

    /// Shebang der Datei unter `path` (Symlinks werden aufgelöst); `nil`, wenn sie nicht mit `#!` beginnt, fehlt,
    /// nicht lesbar oder keine reguläre Datei ist.
    static func shebang(atPath path: String) -> Shebang? {
        FileType.contentsOfRegularFile(atPath: path, maximumLength: maximumHeadLength).flatMap(shebang(in:))
    }

    /// Shebang am Anfang von `head` (höchstens `maximumHeadLength` Bytes zählen); leerer Interpreter, wenn die Zeile
    /// dort nicht endet.
    static func shebang(in head: Data) -> Shebang? {
        let head = head.prefix(maximumHeadLength)
        guard head.starts(with: marker) else { return nil }
        let rest = head.dropFirst(marker.count)
        guard let end = rest.firstIndex(where: isLineEnd) else { return Shebang(interpreter: "", arguments: []) }
        let parts = rest[..<end].split(whereSeparator: isSeparator).map { String(decoding: $0, as: UTF8.self) }
        return Shebang(interpreter: parts.first ?? "", arguments: Array(parts.dropFirst()))
    }

    private static func isLineEnd(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "#")
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }
}
