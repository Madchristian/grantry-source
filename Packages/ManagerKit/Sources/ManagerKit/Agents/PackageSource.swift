/// Woher der Code eines MCP-Servers kommt (Spec §5) – abgeleitet aus Befehl und Argumenten.
public enum PackageSource: Hashable, Sendable, Codable {
    /// npm-Paket über `npx`, `bunx`, `pnpm dlx`, `yarn dlx`, `npm exec` oder `deno run npm:`; `version` wie angegeben
    /// (auch `latest`, `^1`). Git-/URL-Angaben stehen vollständig in `package`, `version` ist dort nur ein Commit-Hash.
    case npm(package: String, version: String?)
    /// PyPI-Paket über `uvx`, `uv tool run`, `pipx run`; `version` nur bei exakter Festlegung (`==`, `===`, `@`,
    /// Commit-Hash bei Git-URLs). Ein Platzhalter (`1.*`) bleibt erhalten, gilt aber als nicht festgelegt.
    case pypi(package: String, version: String?)
    /// Container-Image über `docker run`/`podman run`; `reference` = Tag oder `sha256:`-Digest.
    case container(image: String, reference: String?)
    /// Programm mit absolutem Pfad – bei Interpretern wie `node` oder `python3` das Skript, das sie starten (absoluter Pfad),
    /// sonst der Pfad des Interpreters selbst. Auch absolute Paketverzeichnisse von Runnern (`npx /abs/pkg`,
    /// `uvx --from file:///abs/pkg`).
    case localProgram(path: String)
    /// Befehl aus dem `PATH` (z. B. `uv`, `xcrun`) oder relativer Pfad (`./bin/server`, `npx ./lokal`, `~/bin/x`; dann mit
    /// vollem Text) – Grantry kennt `PATH` und Arbeitsverzeichnis des Tools nicht.
    case command(name: String)
    /// Entfernter Server.
    case remote(host: String)

    /// `true`, wenn jeder Start neuen Code laden kann: npm ohne vollständige Version (oder Commit-Hash), PyPI ohne exakte
    /// Version (oder mit Platzhalter), Container ohne Tag oder mit `latest`.
    public var isUnpinned: Bool {
        switch self {
        case .npm(_, let version): !Self.isExactVersion(version)
        case .pypi(_, let version): version.map { $0.contains("*") } ?? true
        case .container(_, let reference): reference == nil || reference == "latest"
        case .localProgram, .command, .remote: false
        }
    }

    /// Paket- bzw. Image-Name; `nil` für Programme, Befehle und entfernte Server.
    public var packageName: String? {
        switch self {
        case .npm(let package, _), .pypi(let package, _): package
        case .container(let image, _): image
        case .localProgram, .command, .remote: nil
        }
    }

    /// Vollständiges Semver (`1.2.3`, `v1.2.3`, `1.2.3-beta.1`, `1.2.3+build`) oder Commit-Hash; `1`, `1.2`, `^1.0.0`,
    /// `1.x` und `latest` legen nichts fest.
    private static func isExactVersion(_ version: String?) -> Bool {
        guard let version else { return false }
        return isCommitHash(version)
            || version.wholeMatch(of: /v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?/) != nil
    }

    /// 40-stelliger Hexadezimal-Hash eines Git-Commits.
    static func isCommitHash<Text: StringProtocol>(_ text: Text) -> Bool {
        text.count == 40 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
