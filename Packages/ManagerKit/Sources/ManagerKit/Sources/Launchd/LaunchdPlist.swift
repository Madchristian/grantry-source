import Foundation

/// Relevanter Ausschnitt einer launchd-Plist.
struct LaunchdPlist: Decodable, Equatable {
    let label: String
    let program: String?
    let programArguments: [String]?
    let disabled: Bool
    let associatedBundleIdentifiers: [String]
    /// `LimitLoadToSessionType`; `nil`, wenn der Schlüssel fehlt oder keinen String bzw. keine String-Liste enthält.
    let sessionTypes: [String]?
    /// `EnvironmentVariables` setzt einen eigenen `PATH` – dann ist offen, was `env` findet. Ein Dictionary, das sich
    /// nicht als Zeichenketten lesen lässt, gilt im Zweifel ebenfalls als eigener `PATH`.
    let overridesPath: Bool

    init(
        label: String, program: String?, programArguments: [String]?, disabled: Bool,
        associatedBundleIdentifiers: [String], sessionTypes: [String]? = nil, overridesPath: Bool = false
    ) {
        self.label = label
        self.program = program
        self.programArguments = programArguments
        self.disabled = disabled
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
        self.sessionTypes = sessionTypes
        self.overridesPath = overridesPath
    }

    static func decode(_ data: Data) throws -> LaunchdPlist {
        try PropertyListDecoder().decode(LaunchdPlist.self, from: data)
    }

    /// Ausgeführtes Programm: `Program`, sonst erstes Element von `ProgramArguments`.
    var executable: String? { program ?? programArguments?.first }

    /// Startet einen Interpreter (`ScriptInterpreter`) mit Argumenten, etwa `/bin/sh -c ~/Library/.x/evil`.
    /// `ProgramArguments` ist `argv` samt `argv[0]` – auch neben `Program` –, Argumente sind also ab dem zweiten Element.
    var launchesInterpreter: Bool {
        guard let executable, let arguments = programArguments else { return false }
        return arguments.count > 1 && ScriptInterpreter.matches(executable)
    }

    /// Äußerstes `.app`-Bundle im Programmpfad, z. B. `/Applications/Foo.app`.
    var owningAppBundlePath: String? {
        guard let executable, let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    private enum CodingKeys: String, CodingKey {
        case label = "Label", program = "Program", programArguments = "ProgramArguments"
        case disabled = "Disabled", associatedBundleIdentifiers = "AssociatedBundleIdentifiers"
        case sessionTypes = "LimitLoadToSessionType"
        case environmentVariables = "EnvironmentVariables"
    }

    /// Nur `Label` ist Pflicht. Manche System-Plists (z. B. `com.apple.usbaudiod.plist`) tragen `Disabled`
    /// als Bedingungs-Dictionary statt als Bool; ein falscher Typ in `Program`, `ProgramArguments` oder
    /// `Disabled` verwirft daher nur das jeweilige Feld statt den ganzen Eintrag. `AssociatedBundleIdentifiers` und
    /// `LimitLoadToSessionType` dürfen ein String oder eine String-Liste sein.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        program = (try? container.decodeIfPresent(String.self, forKey: .program)) ?? nil
        programArguments = (try? container.decodeIfPresent([String].self, forKey: .programArguments)) ?? nil
        disabled = (try? container.decodeIfPresent(Bool.self, forKey: .disabled)) ?? false
        associatedBundleIdentifiers = Self.stringList(in: container, forKey: .associatedBundleIdentifiers) ?? []
        sessionTypes = Self.stringList(in: container, forKey: .sessionTypes)
        overridesPath = Self.overridesPath(in: container)
    }

    private static func overridesPath(in container: KeyedDecodingContainer<CodingKeys>) -> Bool {
        guard container.contains(.environmentVariables) else { return false }
        guard let variables = try? container.decode([String: String].self, forKey: .environmentVariables) else { return true }
        return variables["PATH"] != nil
    }

    /// String-Liste oder einzelner String als einelementige Liste; `nil` bei fehlendem Schlüssel oder anderem Typ.
    private static func stringList(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [String]? {
        if let list = try? container.decode([String].self, forKey: key) { return list }
        if let single = try? container.decode(String.self, forKey: key) { return [single] }
        return nil
    }
}
