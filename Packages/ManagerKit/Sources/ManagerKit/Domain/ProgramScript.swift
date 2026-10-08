/// Programm eines launchd-Eintrags, das ein Skript ist (beginnt mit `#!`), mit dem Interpreter aus der Shebang-Zeile.
///
/// Skripte tragen meist keine Signatur; ob ein unsigniertes Skript unauffällig ist, entscheidet der Interpreter, den
/// der Kernel damit startet. Sonst machte `#!/Users/x/Library/.x/evil` jedes unsignierte Programm zum harmlosen
/// „Skript“.
public struct ProgramScript: Codable, Hashable, Sendable {
    /// Interpreter-Pfad aus der Shebang-Zeile (`/bin/zsh`, `/usr/bin/env`); leer, wenn die Zeile keinen nennt.
    public var interpreter: String
    /// Übrige Bestandteile der Shebang-Zeile (`["python3"]` bei `#!/usr/bin/env python3`).
    public var arguments: [String]
    /// Signatur von `interpreter`; `nil`, wenn er nicht absolut ist oder fehlt.
    public var interpreterSigning: SigningInfo?
    /// Bei `/usr/bin/env <name>` das Programm, das `env` startet – nur in der eindeutigen Form (`Shebang.envProgram`)
    /// und ohne eigenen `PATH` der Plist über launchds Standard-PATH aufgelöst (`LaunchdSearchPath`); sonst `nil`.
    public var resolvedEnvProgram: ResolvedProgram?

    /// Über den `PATH` gefundenes Programm samt Signatur.
    public struct ResolvedProgram: Codable, Hashable, Sendable {
        public var path: String
        public var signing: SigningInfo?

        public init(path: String, signing: SigningInfo?) {
            self.path = path
            self.signing = signing
        }
    }

    public init(
        interpreter: String, arguments: [String] = [], interpreterSigning: SigningInfo?,
        resolvedEnvProgram: ResolvedProgram? = nil
    ) {
        self.interpreter = interpreter
        self.arguments = arguments
        self.interpreterSigning = interpreterSigning
        self.resolvedEnvProgram = resolvedEnvProgram
    }

    private enum CodingKeys: String, CodingKey {
        case interpreter, arguments, interpreterSigning, resolvedEnvProgram
    }

    /// Ältere Snapshots tragen `envProgram` (nur den Namen) statt `arguments` und `resolvedEnvProgram`: `env` gilt dann
    /// bis zum nächsten Scan als nicht aufgelöst.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interpreter = try container.decode(String.self, forKey: .interpreter)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        interpreterSigning = try container.decodeIfPresent(SigningInfo.self, forKey: .interpreterSigning)
        resolvedEnvProgram = try container.decodeIfPresent(ResolvedProgram.self, forKey: .resolvedEnvProgram)
    }

    /// Wie weit der Interpreter belegt ist.
    ///
    /// Die Herabstufung auf niedrig ist nur ein Komfort für eindeutig harmlose Fälle: Im Zweifel – relativer Pfad,
    /// fehlende oder nicht prüfbare Signatur (der Installationsort allein zählt hier nicht) – ist der Interpreter
    /// `.unknown`. Bewusst niedrig bleibt ein belegter Interpreter, der seinerseits beliebigen Code startet
    /// (`#!/bin/sh` mit `exec ~/evil`): wie `/bin/sh -c …` in der Plist (`AutostartItem.launchesInterpreter`).
    public enum InterpreterOrigin: Sendable {
        /// Nachgewiesene Herkunft: Apple-Signatur oder eine Signatur mit Zertifikat (App Store, Developer ID,
        /// Development) – wie ein solches Programm selbst unauffällig. Bei `env` gilt das für das aufgelöste Programm
        /// (`resolvedEnvProgram`), `env` selbst muss Apples `/usr/bin/env` sein.
        case verified
        /// Nur ad hoc signiert (typisch für Homebrew) – wie ein ad hoc signiertes Programm.
        case adHoc
        /// Unsigniert, nicht prüfbar, fehlend, relativ oder `env` ohne eindeutig aufgelöstes Programm – wie ein
        /// unsigniertes Programm.
        case unknown
    }

    public var interpreterOrigin: InterpreterOrigin {
        guard Shebang.isEnvPath(interpreter) else { return Self.origin(of: interpreter, signing: interpreterSigning) }
        guard interpreter == Shebang.systemEnv, Self.origin(of: interpreter, signing: interpreterSigning) == .verified,
              let resolved = resolvedEnvProgram else { return .unknown }
        return Self.origin(of: resolved.path, signing: resolved.signing)
    }

    /// Interpreter samt Argumenten, wie in der Shebang-Zeile (`/usr/bin/env python3`); Steuerzeichen wie `\r`
    /// erscheinen maskiert (`/bin/sh\\r`).
    public var interpreterDescription: String {
        Self.visible(([interpreter] + arguments).joined(separator: " "))
    }

    private static let certificateKinds: Set<SigningInfo.Kind> = [.appStore, .developerID, .development]

    /// Herkunft des Programms unter `path`: belegt nur mit absolutem Pfad und geprüfter Signatur.
    private static func origin(of path: String, signing: SigningInfo?) -> InterpreterOrigin {
        guard path.hasPrefix("/"), let signing, signing.kind != .unknown else { return .unknown }
        if signing.isAppleSigned || certificateKinds.contains(signing.kind) { return .verified }
        return signing.kind == .adHoc ? .adHoc : .unknown
    }

    /// `text` mit maskierten Steuerzeichen (`\r` → `\\r`).
    private static func visible(_ text: String) -> String {
        text.unicodeScalars.map { $0.properties.generalCategory == .control ? $0.escaped(asASCII: true) : String($0) }
            .joined()
    }
}
