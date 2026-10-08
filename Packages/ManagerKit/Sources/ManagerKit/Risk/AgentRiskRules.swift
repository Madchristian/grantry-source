import Foundation

extension MCPServerEntry {
    /// „Name“ (Ort) – Subjekt der Meldungen aller Agenten-Regeln: „„filesystem“ (Claude Desktop)“,
    /// „„web“ (Claude Code (Projekt web))“.
    var findingSubject: String { "„\(name)“ (\(locationDescription))" }
}

/// npm-/PyPI-Paket ohne festgelegte Version oder Container ohne Tag/mit `latest` (**niedrig**, Spec §5): Jeder Start
/// kann neuen Code laden. Keine Bewertung des Pakets selbst.
public struct UnpinnedPackageRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.mcpServers.compactMap { server in
            guard server.packageSource.isUnpinned, let package = server.packageSource.packageName else { return nil }
            return RiskFinding(
                rule: .unpinnedPackage, severity: .low, recordID: server.id,
                message: "\(server.findingSubject) kann bei jedem Start eine neuere Version von \(package) laden"
            )
        }
    }
}

/// Umgebungs- oder Header-Name, der nach Geheimnis aussieht, oder ein Geheimnis in Argumenten/URL (**niedrig**). Der
/// Wert selbst ist Grantry unbekannt (nie gelesen) – daher „mögliches“ Geheimnis. Trifft beides zu, nennt die Meldung
/// beides. Liegt die Datei außerhalb des Benutzerordners und ist für Gruppe oder alle lesbar, nennt sie das ebenfalls.
public struct PlaintextSecretRule: RiskRule {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = PathDisplay.trimmingTrailingSlashes(home)
    }

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.mcpServers.compactMap { server in
            var what = (server.environmentKeys + server.headerKeys).filter(SecretNames.looksSecret)
            if server.hasSecretInArguments { what.append(Self.argumentsLabel(of: server.transport)) }
            guard !what.isEmpty else { return nil }
            let shared = isSharedOutsideHome(server) ? " – Datei für andere lesbar" : ""
            return RiskFinding(
                rule: .plaintextSecret, severity: .low, recordID: server.id,
                message: "\(server.findingSubject): mögliches Geheimnis im Klartext in der Konfiguration (\(what.joined(separator: ", ")))\(shared)"
            )
        }
    }

    /// Bei entfernten Servern maskiert `ArgumentRedactor` die URL, bei lokalen die Argumente.
    private static func argumentsLabel(of transport: MCPTransport) -> String {
        if case .remote = transport { "URL" } else { "Argumente" }
    }

    private func isSharedOutsideHome(_ server: MCPServerEntry) -> Bool {
        guard let mode = server.configFileMode else { return false }
        return mode & 0o044 != 0 && !server.configPath.hasPrefix(home + "/")
    }
}

/// Konfigurationsdatei für alle Benutzer beschreibbar (**mittel**): Jeder Benutzer könnte Server eintragen.
///
/// Grenze: Der Befund hängt an einem Server, bewertet werden also nur Dateien, die mindestens einen Server enthalten –
/// eine beschreibbare Datei ohne Server (oder nur mit Freigaben) bleibt unbeachtet. Je Server ein Befund; die Meldung
/// nennt Server und Datei.
public struct WritableAgentConfigRule: RiskRule {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = PathDisplay.trimmingTrailingSlashes(home)
    }

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.mcpServers.compactMap { server in
            guard let mode = server.configFileMode, mode & 0o002 != 0 else { return nil }
            return RiskFinding(
                rule: .writableConfig, severity: .medium, recordID: server.id,
                message: "\(server.findingSubject): Konfigurationsdatei \(PathDisplay.abbreviatingHome(server.configPath, home: home)) ist für alle Benutzer beschreibbar"
            )
        }
    }
}

/// Lokales Programm, dem man nicht trauen sollte (Spec §5; nur bei vorhandenem Programm):
/// - in einem temporären, geteilten oder Download-Ordner (`/tmp`, `/var/tmp`, `/var/folders`, `/Users/Shared`,
///   `~/Downloads`, jeweils auch unter `/private`): **mittel** – jeder andere Prozess kann es austauschen;
/// - unsigniert: **mittel**;
/// - nur ad hoc signiert: **niedrig** – typisch für Homebrew und selbst gebaute Go-/Rust-Programme.
///
/// Der Ort geht der Signatur vor. Ohne Signaturangabe (Skripte, nicht prüfbar) zählt nur der Ort. Pfade werden vor dem
/// Vergleich bereinigt (`..`, `.`) und ohne Rücksicht auf Groß-/Kleinschreibung verglichen (APFS).
public struct UntrustedMCPProgramRule: RiskRule {
    /// Warum ein Ort nicht vertrauenswürdig ist; bestimmt den Meldungstext.
    private enum Location {
        case downloads, temporaryOrShared

        var statement: String {
            switch self {
            case .downloads: "das im Download-Ordner liegt"
            case .temporaryOrShared: "das in einem temporären bzw. geteilten Ordner liegt"
            }
        }
    }

    private static let temporaryOrSharedPrefixes = [
        "/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/var/folders/", "/private/var/folders/", "/users/shared/",
    ]

    private let home: String
    private let downloadsPrefix: String

    public init(home: String = NSHomeDirectory()) {
        self.home = PathDisplay.trimmingTrailingSlashes(home)
        downloadsPrefix = (self.home + "/Downloads/").lowercased()
    }

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.mcpServers.compactMap { server in
            guard case .localProgram(let path) = server.packageSource, server.programPresence == .present,
                  let (severity, statement) = verdict(for: path, signing: server.programSigning) else { return nil }
            return RiskFinding(
                rule: .untrustedProgram, severity: severity, recordID: server.id,
                message: "\(server.findingSubject) startet \(PathDisplay.abbreviatingHome(path, home: home)), \(statement)"
            )
        }
    }

    private func verdict(for path: String, signing: SigningInfo?) -> (RiskFinding.Severity, String)? {
        if let location = location(of: path) { return (.medium, location.statement) }
        switch signing?.kind {
        case .unsigned: return (.medium, "das nicht signiert ist")
        case .adHoc: return (.low, "das nur ad hoc signiert ist")
        default: return nil
        }
    }

    private func location(of path: String) -> Location? {
        let normalized = (path as NSString).standardizingPath.lowercased()
        if normalized.hasPrefix(downloadsPrefix) { return .downloads }
        return Self.temporaryOrSharedPrefixes.contains(where: normalized.hasPrefix) ? .temporaryOrShared : nil
    }
}

/// Entfernter Server über unverschlüsseltes `http://` zu einem fremden Host (**mittel**); ausgenommen sind `localhost`
/// (auch `*.localhost`), `127.0.0.0/8`, `::1`, `0.0.0.0` und `::` sowie IPv4-gemappte Adressen daraus
/// (`::ffff:127.0.0.1`).
public struct CleartextRemoteRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.mcpServers.compactMap { server in
            guard server.transport.usesCleartextHTTP, let host = server.transport.remoteHost, !Self.isLocal(host) else { return nil }
            return RiskFinding(
                rule: .cleartextRemote, severity: .medium, recordID: server.id,
                message: "\(server.findingSubject) verbindet sich unverschlüsselt mit \(host)"
            )
        }
    }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || isLocalAddress(host)
    }

    /// Loopback (`127.0.0.0/8`, `::1`) oder unspezifiziert (`0.0.0.0`, `::`) – als vollständige Adresse; `127.example.com`
    /// ist ein fremder Host. IPv6 in jeder Schreibweise (`inet_pton`).
    private static func isLocalAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return isLocal(ipv4: withUnsafeBytes(of: ipv4) { Array($0) }) }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) { return bytes[15] <= 1 }
        let isIPv4Mapped = bytes[..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        return isIPv4Mapped && isLocal(ipv4: Array(bytes[12...]))
    }

    private static func isLocal(ipv4 bytes: [UInt8]) -> Bool {
        bytes[0] == 127 || bytes.allSatisfy { $0 == 0 }
    }
}

/// Aktive automatische Freigabe (**niedrig**, Hinweis).
public struct ActiveAutoApprovalRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.agentAutoApprovals.map {
            RiskFinding(rule: .autoApproval, severity: .low, recordID: $0.id, message: "\($0.locationDescription): \($0.message)")
        }
    }
}
