/// Wert einer Konfigurationsdatei – gemeinsamer Baum für JSON, JSONC und TOML (Spec §3). Die Extraktion arbeitet nur
/// auf diesem Baum, unabhängig vom Format.
enum ConfigValue: Hashable, Sendable {
    case object(ConfigObject)
    case array([ConfigValue])
    case string(String)
    /// Zahl im Quelltext (Ganz- oder Gleitkommazahl) – nur verglichen und angezeigt, nie gerechnet.
    case number(String)
    case bool(Bool)
    case null
    /// Wert unter einem geschwärzten Schlüssel (`redactedKeys`): beim Parsen übersprungen, sein Inhalt wird nie
    /// gespeichert. Objekte darunter behalten ihre Schlüsselnamen, deren Werte sind ebenfalls `redacted`.
    case redacted

    var object: ConfigObject? {
        if case .object(let object) = self { object } else { nil }
    }

    var array: [ConfigValue]? {
        if case .array(let array) = self { array } else { nil }
    }

    var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var bool: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    /// Textform skalarer Werte für den Vergleich mit Katalogwerten (`"true"`, `"never"`, `"1"`); sonst `nil`.
    var scalarText: String? {
        switch self {
        case .string(let string): string
        case .number(let number): number
        case .bool(let bool): bool ? "true" : "false"
        case .object, .array, .null, .redacted: nil
        }
    }

    /// Wert unter dem Schlüsselpfad; `nil`, wenn ein Glied fehlt oder kein Objekt ist. Leerer Pfad: der Wert selbst.
    func value(at path: [String]) -> ConfigValue? {
        path.reduce(Optional(self)) { value, key in value?.object?[key] }
    }

    /// Strings der Liste unter `path` (Namenslisten wie `disabledMcpServers`); andere Elemente werden übergangen,
    /// fehlender Pfad oder keine Liste ergibt eine leere Liste.
    func strings(at path: [String]?) -> [String] {
        path.flatMap { value(at: $0)?.array }?.compactMap(\.string) ?? []
    }
}

/// Objekt mit Schlüsseln in Dokumentreihenfolge. Doppelte Schlüssel bleiben erhalten; gelesen wird – wie `JSON.parse`
/// in den Tools – der letzte.
///
/// Zugriff und `keys` sind O(1): ein Index merkt sich die Position des letzten Vorkommens, die Schlüsselliste ohne
/// Dubletten wird beim Anfügen mitgeführt. Sonst würde die Extraktion bei einem präparierten Objekt mit sehr vielen
/// Schlüsseln quadratisch. Gleichheit und Hash gelten nur für `members`, der Index zählt nicht.
struct ConfigObject: Hashable, Sendable {
    struct Member: Hashable, Sendable {
        let key: String
        let value: ConfigValue

        init(key: String, value: ConfigValue) {
            self.key = key
            self.value = value
        }
    }

    private(set) var members: [Member] = []
    /// Schlüssel ohne Dubletten, in der Reihenfolge ihres ersten Vorkommens.
    private(set) var keys: [String] = []
    /// Position des **letzten** Vorkommens je Schlüssel in `members`.
    private var lastPosition: [String: Int] = [:]

    init(members: [Member] = []) {
        self.members.reserveCapacity(members.count)
        for member in members { append(member.key, member.value) }
    }

    subscript(key: String) -> ConfigValue? {
        lastPosition[key].map { members[$0].value }
    }

    mutating func append(_ key: String, _ value: ConfigValue) {
        if lastPosition.updateValue(members.count, forKey: key) == nil { keys.append(key) }
        members.append(Member(key: key, value: value))
    }

    static func == (lhs: ConfigObject, rhs: ConfigObject) -> Bool {
        lhs.members == rhs.members
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(members)
    }
}
