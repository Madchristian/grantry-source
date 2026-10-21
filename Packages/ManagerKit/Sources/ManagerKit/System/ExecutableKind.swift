import Foundation

/// Wie ein gefundenes Werkzeug startet (#220): Davon hängt ab, ob es einen Begleiter wie `node` neben sich braucht.
/// Homebrew-pnpm ist ein eigenständiges Programm mit eingebautem Node, npm ein `env node`-Skript.
enum ExecutableKind: Equatable, Sendable {
    /// Kein Skript (Mach-O): startet ohne Interpreter.
    case binary
    /// `#!/usr/bin/env <name>`: sucht `name` über `PATH`.
    case environmentScript(String)
    /// `#!<absoluter Pfad>`: startet über genau diesen Interpreter.
    case script(interpreter: String)

    /// Art der Datei unter `path` (Symlinks werden aufgelöst); `nil`, wenn sie fehlt, leer, keine reguläre Datei oder
    /// der Shebang unklar ist (`env` mit Optionen, relativer Interpreter).
    static func of(_ path: String) -> ExecutableKind? {
        FileType.contentsOfRegularFile(atPath: path, maximumLength: ScriptFile.maximumHeadLength).flatMap(parse)
    }

    static func parse(_ head: Data) -> ExecutableKind? {
        guard !head.isEmpty else { return nil }
        guard let shebang = ScriptFile.shebang(in: head) else { return .binary }
        if let name = shebang.envProgram { return .environmentScript(name) }
        guard shebang.interpreter.hasPrefix("/"), !Shebang.isEnvPath(shebang.interpreter) else { return nil }
        return .script(interpreter: shebang.interpreter)
    }
}
