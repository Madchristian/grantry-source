import Foundation

/// Erkennt Namen, die nach Geheimnis aussehen (Spec §5): Umgebungsvariablen, Header, Flags, Query-Parameter.
/// Großzügig – lieber ein Hinweis zu viel als ein Geheimnis im Verlauf –, mit Ausnahmen für harmlose Namen
/// (Schalter, Dateien, Pfade, Modi, Token-Zähler, Verneinungen), damit „Geheimnis im Klartext“ nicht ständig falsch anschlägt.
/// Groß-/Kleinschreibung, `-` und Leerzeichen sind egal (`--api-key`, `Api Key`, `API_KEY`).
enum SecretNames {
    /// Letztes Glied eines Namens (`OPENAI_API_KEY` → `KEY`).
    private static let secretSuffixes: Set<String> = [
        "KEY", "TOKEN", "SECRET", "PAT", "PASS", "PASSWD", "CREDENTIAL", "CREDENTIALS", "APIKEY",
        "AUTH", "AUTHORIZATION", "PASSPHRASE",
    ]
    /// Letztes Glied, das nur hinter einem Präfix ein Passwort ist (`DB_PWD`); allein ist `PWD` das Arbeitsverzeichnis.
    private static let prefixedSecretSuffixes: Set<String> = ["PWD"]
    /// Bestandteile irgendwo im Namen (auch camelCase: `accessToken` → `ACCESSTOKEN`).
    private static let secretFragments = [
        "PASSWORD", "PASSPHRASE", "SECRET", "TOKEN", "APIKEY", "API_KEY", "PRIVATE_KEY", "ACCESS_KEY",
        "PRIVATEKEY", "ACCESSKEY",
    ]
    /// Ganze Namen.
    private static let secretNames: Set<String> = ["COOKIE", "BEARER", "PGPASS"]

    /// Ausnahmen, die auch dann gelten, wenn ein Geheimnis-Bestandteil im Namen steht: Schalter (`--enable-auth`),
    /// Verneinungen (`--no-auth`) und Zähler (`MAX_TOKENS`) als Präfix; Dateien, Pfade, Modi, Typen und Limits sowie
    /// der Tokenizer als Endung. `_URL` und `TOKENS` sind bewusst nicht dabei: URLs können Zugangsdaten enthalten,
    /// und `API_TOKENS=a,b` ist eine Liste echter Token.
    private static let harmlessPrefixes = [
        "NO_", "ENABLE_", "DISABLE_", "SKIP_", "REQUIRE_", "WITHOUT_", "USE_", "MAX_", "MIN_", "NUM_",
    ]
    private static let harmlessSuffixes = ["_FILE", "_PATH", "_DIR", "_TYPE", "_MODE", "_LIMIT", "TOKENIZER"]
    /// `MODEL_MAX_TOKENS`, `maxTokens` – Token-Zähler eines Sprachmodells, keine Zugangs-Token.
    private static let harmlessFragments = ["MAX_TOKENS", "MAXTOKENS"]

    static func looksSecret(_ name: String) -> Bool {
        let normalized = normalize(name)
        guard !normalized.isEmpty, !isHarmless(normalized) else { return false }
        if secretNames.contains(normalized) || secretFragments.contains(where: { normalized.contains($0) }) { return true }
        let segments = normalized.split(separator: "_")
        guard let last = segments.last.map(String.init) else { return false }
        if prefixedSecretSuffixes.contains(last) { return segments.count > 1 }
        return secretSuffixes.contains(last)
    }

    /// Wie `looksSecret`, aber für Schlüssel in Connection-Strings (`Server=x;PWD=y`): dort ist ein einzelnes `PWD`
    /// (ODBC) ein Passwort.
    static func isConnectionStringSecret(_ name: String) -> Bool {
        looksSecret(name) || normalize(name) == "PWD"
    }

    /// Großbuchstaben, ohne führende `-`, mit `_` statt `-` und Leerzeichen (`--api-key` → `API_KEY`).
    private static func normalize(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).drop { $0 == "-" })
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func isHarmless(_ normalized: String) -> Bool {
        harmlessPrefixes.contains { normalized.hasPrefix($0) }
            || harmlessSuffixes.contains { normalized.hasSuffix($0) }
            || harmlessFragments.contains { normalized.contains($0) }
    }
}
