/// Schwärzungsregel der Konfigurationsparser: Werte unter einem Schlüssel aus `keys` werden nie gelesen
/// (`ConfigValue.redacted`) – auf jeder Ebene, außer der Schlüssel steht direkt in einem der `exemptParents`.
///
/// `exemptParents` sind Schlüsselpfade von Objekten, deren Schlüssel Namen sind und keine Felder – die Server-Listen
/// (`["mcpServers"]`, `["projects", "*", "mcpServers"]`). Ein Server namens `env` bleibt dort lesbar; das `env` in
/// seinem Objekt ist wieder geschwärzt. `*` in einem Pfad steht für genau einen beliebigen Objektschlüssel (Projektpfade),
/// nie für ein Array-Element.
struct ConfigRedaction: Hashable, Sendable {
    let keys: Set<String>
    let exemptParents: [[String]]

    init(keys: Set<String>, exemptParents: [[String]] = []) {
        self.keys = keys
        self.exemptParents = exemptParents
    }

    /// Keine Schwärzung.
    static let none = ConfigRedaction(keys: [])

    /// `true`, wenn der Wert unter `key` geschwärzt wird; `parentPath` ist der Pfad des umgebenden Objekts, `nil` steht
    /// für ein Array-Element.
    func redacts(_ key: String, under parentPath: [String?]) -> Bool {
        guard keys.contains(key) else { return false }
        return !isExempt(parentCount: parentPath.count) { parentPath[$0] }
    }

    /// `true`, wenn ein Glied von `path` den Wert darunter schwärzt (`nil` steht für ein Array-Element).
    func redacts(path: [String?]) -> Bool {
        path.indices.contains { index in
            guard let key = path[index], keys.contains(key) else { return false }
            return !isExempt(parentCount: index) { path[$0] }
        }
    }

    private func isExempt(parentCount: Int, component: (Int) -> String?) -> Bool {
        exemptParents.contains { pattern in
            pattern.count == parentCount && pattern.indices.allSatisfy { index in
                guard let actual = component(index) else { return false }
                return pattern[index] == "*" || pattern[index] == actual
            }
        }
    }
}
