/// Ein Befehl – Programm und Argumentliste –, maskiert durch den `ArgumentRedactor`, samt Fingerabdruck der Rohwerte,
/// wenn dabei etwas maskiert wurde (#137). Alles, was eine Quelle aus Programm und Argumenten nach außen gibt (Snapshot,
/// Anzeige, Protokoll), stammt von hier; die Rohwerte bleiben in der Quelle. Der Fingerabdruck erkennt die Änderung eines
/// maskierten Geheimnisses, ohne es zu speichern.
public struct MaskedCommand: Hashable, Sendable {
    /// Maskiertes Programm: das eigene Programm, sonst das maskierte erste Argument (`argv[0]`); `nil` ohne beides.
    public let program: String?
    /// Maskierte Argumentliste.
    public let arguments: [String]
    /// `nil`, wenn nichts maskiert wurde – dann zeigen schon `program` und `arguments` jede Änderung.
    public let fingerprint: SecretFingerprint?
    /// Mindestens ein maskierter Wert war ein Geheimnis im Klartext (siehe `ArgumentRedactor.Arguments`).
    public let containsSecret: Bool
    /// Beim Maskieren ermittelt; bleibt auch nach Entfernen eines Interpreter-Symlinks wahr.
    public let hasHiddenScript: Bool

    /// - Parameters:
    ///   - program: eigenes Programm (launchd `Program`); `nil`, wenn `arguments.first` das Programm ist.
    ///   - arguments: Argumentliste samt `argv[0]`. Ob darin ein Shell-Skript steht (`sh -c …`), entscheidet das
    ///     tatsächliche Programm (`program`, sonst `argv[0]`); ein Skript steht ganz oder gar nicht da.
    ///   - resolvingPath: löst Programm- und Argumentpfade samt Symlinks auf, falls die Quelle das kann – erkennt
    ///     Shells hinter Symlinks (`/usr/local/bin/mysh` → `/bin/zsh`), auch hinter `env`.
    public init(
        program: String?, arguments: [String], resolvingPath: ((String) -> String?)? = nil,
        fingerprinter: SecretFingerprinter
    ) {
        let redactedArguments = ArgumentRedactor.redact(arguments: arguments, program: program, resolvingPath: resolvingPath)
        let redactedProgram = program.map { ArgumentRedactor.redact(arguments: [$0]) }
        self.arguments = redactedArguments.values
        hasHiddenScript = redactedArguments.hasHiddenScript
        self.program = program == nil ? redactedArguments.values.first : redactedProgram?.values.first ?? ArgumentRedactor.mask
        containsSecret = redactedArguments.containsSecret || redactedProgram?.containsSecret == true
        let isMasked = redactedArguments.values != arguments || self.program != (program ?? arguments.first)
        // Das Programm geht als eigenes erstes Element mit Präfix ein: „kein `Program`“ (`0`) bleibt von jedem
        // gesetzten Programm (`1…`) unterscheidbar.
        fingerprint = isMasked ? fingerprinter.fingerprint(of: [program.map { "1" + $0 } ?? "0"] + arguments) : nil
    }
}
