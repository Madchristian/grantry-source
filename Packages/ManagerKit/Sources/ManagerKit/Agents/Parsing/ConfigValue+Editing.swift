/// Baum-Operationen für die Nachprüfung einer textuellen Änderung (Stufe 2): Der neu geparste Text muss dem alten
/// Baum mit genau dieser einen Änderung entsprechen – sonst wird nichts geschrieben.
extension ConfigValue {
    /// Ohne den Schlüssel am Ende von `path` (alle Vorkommen). Zwischenschlüssel werden in allen Vorkommen verfolgt, auch
    /// in verdeckten Dubletten. Unverändert, wenn der Weg dorthin fehlt oder durch ein Nicht-Objekt (etwa ein Array) führt.
    func removing(_ path: [String]) -> ConfigValue {
        guard let key = path.first, let object else { return self }
        guard path.count > 1 else {
            return .object(ConfigObject(members: object.members.filter { $0.key != key }))
        }
        guard object[key] != nil else { return self }
        return .object(ConfigObject(members: object.members.map { member in
            member.key == key ? ConfigObject.Member(key: key, value: member.value.removing(Array(path.dropFirst()))) : member
        }))
    }

    /// Mit `value` unter `path`: ersetzt alle Vorkommen des letzten Schlüssels oder hängt ihn an; Zwischenschlüssel werden
    /// in allen Vorkommen verfolgt, fehlende Objekte auf dem Weg angelegt. Unverändert, wenn ein Glied auf dem Weg kein
    /// Objekt ist (etwa ein Array).
    func setting(_ path: [String], to value: ConfigValue) -> ConfigValue {
        guard let key = path.first else { return value }
        guard let object else { return self }
        let rest = Array(path.dropFirst())
        guard object[key] != nil else {
            var members = object.members
            members.append(ConfigObject.Member(key: key, value: ConfigValue.object(ConfigObject()).setting(rest, to: value)))
            return .object(ConfigObject(members: members))
        }
        return .object(ConfigObject(members: object.members.map { member in
            member.key == key ? ConfigObject.Member(key: key, value: member.value.setting(rest, to: value)) : member
        }))
    }

    /// Entfernt von `path` aufwärts jedes Objekt, das leer ist, bis zum ersten nicht leeren – so, wie TOML eine nur
    /// implizit angelegte Tabelle (`[a.b.x]` ohne `[a.b]`) nach dem Entfernen von `x` gar nicht mehr kennt. Nur für TOML:
    /// Ob eine Tabelle explizit war, weiß der Baum nicht – ein leerer expliziter Vorfahr (`[a]` über implizitem `a.b`)
    /// passt weder zu diesem noch zum unveränderten Baum, die Nachprüfung lehnt dann ab (sicher, nur unnötig streng).
    func removingEmptyObjects(along path: [String]) -> ConfigValue {
        var result = self
        var current = path
        while !current.isEmpty, let object = result.value(at: current)?.object, object.members.isEmpty {
            result = result.removing(current)
            current.removeLast()
        }
        return result
    }

    /// Inhaltlich gleich: Objekte unabhängig von der Schlüsselreihenfolge (je Schlüssel zählt der letzte Wert, wie beim
    /// Lesen – verdeckte Dubletten zählen nicht), Arrays in Reihenfolge, sonst exakt (Zahlen als Text: `1.0` ≠ `1`).
    ///
    /// **Grenze:** `.redacted` ist gleich `.redacted`. Geschwärzte Werte (`env`, `headers` …) liest der Parser nie, die
    /// Nachprüfung sieht Änderungen an ihnen also nicht. Das ist bewusst: Die Editoren übernehmen Text außerhalb der
    /// geänderten Spannen byte-genau, und Geheimwerte gelangen auch für die Nachprüfung nie in den Speicher.
    func isEquivalent(to other: ConfigValue) -> Bool {
        switch (self, other) {
        case (.object(let lhs), .object(let rhs)):
            guard Set(lhs.keys) == Set(rhs.keys) else { return false }
            return lhs.keys.allSatisfy { key in
                guard let left = lhs[key], let right = rhs[key] else { return false }
                return left.isEquivalent(to: right)
            }
        case (.array(let lhs), .array(let rhs)):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.isEquivalent(to: $1) }
        default:
            return self == other
        }
    }
}
