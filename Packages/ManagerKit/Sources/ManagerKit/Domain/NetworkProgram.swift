import Foundation

/// Ein Programm laut Pfad und Signatur – gemeinsame Einstufung für lauschende Dienste (`NetworkListener`) und die
/// Netzwerkaktivität (`NetworkActivityRow`): Name, zugehörige App und ob es ein Dienst von macOS ist.
public struct NetworkProgram: Hashable, Sendable {
    public let executablePath: String
    public let signing: SigningInfo

    public init(executablePath: String, signing: SigningInfo) {
        self.executablePath = executablePath
        self.signing = signing
    }

    /// Letzter Pfadbestandteil (`pbi_name` und nettop kürzen auf 15 bzw. 32 Zeichen).
    public var processName: String { (executablePath as NSString).lastPathComponent }

    /// Skriptsprache oder Shell (`ScriptInterpreter`).
    public var isInterpreter: Bool { ScriptInterpreter.matches(executablePath) }

    /// Das Programm tut, was Skript oder Argumente sagen – ein Interpreter (`ScriptInterpreter`, `python3 -m
    /// http.server`) oder ein Netzwerkwerkzeug (`NetworkTool`, `nc -l 4444`). Seine Signatur belegt nichts über den
    /// Dienst dahinter.
    public var isInstructionDriven: Bool { isInterpreter || NetworkTool.matches(executablePath) }

    /// Dienst von macOS: bei bekannter Signatur nur Apple-signiert, sonst (`.unknown`, etwa nach Zeitüberschreitung)
    /// ein versiegeltes Systemverzeichnis (`AppleComponent.isSystemPath`).
    ///
    /// Strenger als `AppleComponent.hasAppleOrigin`: Xcode-Bundles in `/Applications` zählen ohne Signatur nicht, denn
    /// dort darf jeder Admin schreiben, und `.unknown` entsteht auch bei absichtlich gebrochener Signatur. Ein
    /// Interpreter oder Netzwerkwerkzeug (`isInstructionDriven`) ist nie ein Apple-Dienst, auch Apple-signiert oder im
    /// Systempfad: Die Herkunft des Werkzeugs sagt nichts über den Dienst, den es auf Anweisung öffnet.
    public var isAppleService: Bool {
        guard !isInstructionDriven else { return false }
        return signing.kind == .unknown ? AppleComponent.isSystemPath(executablePath) : signing.isAppleSigned
    }

    /// Äußerstes `.app`-Bundle im eigenen Programmpfad.
    public var bundlePath: String? { Self.outermostBundle(in: executablePath) }

    /// Name der zugehörigen App, sonst des Prozesses – ein `python3` aus iTerm heißt `python3`.
    public var title: String { bundlePath.map(Self.appName(ofBundle:)) ?? processName }

    /// Äußerstes `.app`-Bundle in `path`; `nil`, wenn der Pfad in keinem liegt.
    public static func outermostBundle(in path: String) -> String? {
        path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
    }

    /// „/Applications/Visual Studio Code.app“ → „Visual Studio Code“.
    public static func appName(ofBundle bundlePath: String) -> String {
        ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
