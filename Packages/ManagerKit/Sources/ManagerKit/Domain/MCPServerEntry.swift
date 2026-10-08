import Foundation

/// Geltungsbereich eines Agenten-Eintrags (Spec §4). Die Fallnamen und Labels (`user`, `project(path:)`, `system`)
/// sind Teil des Snapshot-Formats – nicht umbenennen.
public enum AgentScope: Hashable, Sendable, Codable {
    /// Benutzerweite Konfiguration.
    case user
    /// Projektbezogen; `path` ist der Projektordner, wie das Tool ihn registriert.
    case project(path: String)
    /// Verwaltete Systemkonfiguration (nur lesend).
    case system

    /// Bestandteil der Identität (`MCPServerEntry.id`, `AgentAutoApproval.id`); `RecordIdentity` maskiert Trennzeichen.
    var identityComponent: String {
        switch self {
        case .user: "user"
        case .project(let path): "project:\(path)"
        case .system: "system"
        }
    }

    /// Kurzbezeichnung des Bereichs: „Projekt web“ (Ordnername), „Projekt“ ohne Ordnernamen (leerer Pfad oder `/`),
    /// „verwaltet“; `nil` für benutzerweit.
    public var scopeLabel: String? {
        switch self {
        case .user: nil
        case .project(let path): path.split(separator: "/").last.map { "Projekt \($0)" } ?? "Projekt"
        case .system: "verwaltet"
        }
    }

    /// Zusatz zum Tool-Namen: „ (Projekt web)“, „ (verwaltet)“, leer für benutzerweit.
    var displaySuffix: String {
        scopeLabel.map { " (\($0))" } ?? ""
    }
}

/// Wie ein MCP-Server erreicht wird. Argumente und URL sind bereits maskiert (`ArgumentRedactor`). Die Fallnamen und
/// Labels (`local(command:arguments:)`, `remote(url:kind:)`) sind Teil des Snapshot-Formats – nicht umbenennen.
public enum MCPTransport: Hashable, Sendable, Codable {
    /// Das Tool startet `command` mit `arguments` als lokalen Prozess.
    case local(command: String, arguments: [String])
    /// Entfernter Server; `kind` wie in der Konfiguration (`sse`, `http`, `streamable-http` …), falls angegeben.
    case remote(url: String, kind: String?)

    /// Host einer entfernten URL in Kleinbuchstaben, ohne Benutzer, Port und abschließenden Punkt (IPv6 ohne Klammern);
    /// `nil` für lokale Server, URLs ohne Schema, ohne Host oder mit unvollständiger IPv6-Klammer.
    public var remoteHost: String? {
        guard case .remote(let url, _) = self, let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        return Self.host(ofAuthority: rest[..<(rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex)])
    }

    /// Host einer URL-Authority (`benutzer@host:port`) wie `remoteHost` – gemeinsam mit `ArgumentRedactor`.
    static func host(ofAuthority authority: Substring) -> String? {
        var authority = authority
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let literal = authority[authority.index(after: authority.startIndex)..<close].lowercased()
            return literal.isEmpty ? nil : literal
        }
        var host = authority.prefix { $0 != ":" }.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// Befehl und Argumente in einer Zeile mit Shell-Quoting (`ShellQuoting`): `npx -y 'a b'`; `nil` für entfernte
    /// Server.
    public var commandLine: String? {
        guard case .local(let command, let arguments) = self else { return nil }
        return ShellQuoting.commandLine([command] + arguments)
    }

    /// Derselbe Transport, mit der heutigen Maskierung erneut maskiert (`ArgumentRedactor`) – für den Vergleich mit
    /// älteren, anders maskierten Snapshots. Bereits Maskiertes bleibt maskiert; ein Skript mit `•••` wird ganz
    /// verborgen. Rein nach Namen, ohne Dateizugriff aus Darstellung/Vergleich; Pfade prüft nur der Scan.
    var remasked: MCPTransport {
        switch self {
        case .local(let command, let arguments):
            let values = ArgumentRedactor.redact(arguments: [command] + arguments, resolvingPath: { _ in nil }).values
            return .local(command: values.first ?? command, arguments: Array(values.dropFirst()))
        case .remote(let url, let kind):
            return .remote(url: ArgumentRedactor.redact(url: url).value, kind: kind)
        }
    }

    /// Entfernter Server über unverschlüsseltes `http://`.
    public var usesCleartextHTTP: Bool {
        guard case .remote(let url, _) = self else { return false }
        return url.lowercased().hasPrefix("http://")
    }
}

/// Ein MCP-Server aus der Konfiguration eines Agenten-Tools (Spec §4). Werte von Umgebungsvariablen und Headern kennt
/// er nicht – nur deren Namen.
public struct MCPServerEntry: InventoryRecord, Codable {
    /// Höchstlänge von `summary` in Zeichen, einschließlich „…“.
    public static let summaryLength = 120

    public var toolID: String
    public var toolName: String
    /// Datei, aus der der Eintrag stammt – Pfad wie im Katalog bzw. `<Projekt>/.mcp.json`, Symlinks nicht aufgelöst.
    public var configPath: String
    /// Bei Einträgen aus Projektdateien die Datei, die das Projekt registriert (`~/.claude.json`); sonst `nil`.
    public var registryPath: String?
    public var scope: AgentScope
    /// Schlüssel des Servers in der Konfiguration.
    public var name: String
    public var transport: MCPTransport
    public var environmentKeys: [String]
    public var headerKeys: [String]
    /// Aktiviert-Schalter des Servers. `nil` heißt bei Servern aus Projektdateien (`registryPath != nil`) „Freigabe
    /// steht noch aus“, sonst „Format kennt keinen Schalter“ (der Server läuft). Fehlt der Schalter in einem Format,
    /// das einen kennt – auch ein Name, der nicht in einer Liste deaktivierter Server steht –, liefert die Extraktion
    /// `true` (sonst meldete das Ergänzen von `"disabled": false` eine Schein-Änderung).
    public var isEnabled: Bool?
    public var packageSource: PackageSource
    /// Argumente oder URL enthielten ein Geheimnis im Klartext (maskiert gespeichert).
    public var hasSecretInArguments: Bool
    /// Fingerabdruck des unmaskierten Transports (Befehl samt Argumenten bzw. URL), falls darin etwas maskiert oder ein
    /// Skript verborgen wurde (#137, wie `AutostartItem.programArgumentsFingerprint`): Ändert sich nur Verborgenes,
    /// bleibt `transport` gleich, der Fingerabdruck nicht. `nil` ohne Maskierung und in älteren Snapshots.
    public var transportFingerprint: SecretFingerprint?
    /// Beim Scan erkanntes, ganz verborgenes Skript; unabhängig vom späteren Zustand des Interpreterpfads.
    public var hasHiddenScript: Bool
    /// Signatur eines lokalen Programms (`PackageSource.localProgram`); sonst `nil`. Nicht signifikant.
    public var programSigning: SigningInfo?
    public var programPresence: Presence
    /// POSIX-Rechte der Konfigurationsdatei (`0o600` …). Nicht signifikant.
    public var configFileMode: UInt16?
    public var source: SourceID

    public init(
        toolID: String, toolName: String, configPath: String, registryPath: String? = nil, scope: AgentScope,
        name: String, transport: MCPTransport, environmentKeys: [String] = [], headerKeys: [String] = [],
        isEnabled: Bool? = nil, packageSource: PackageSource, hasSecretInArguments: Bool = false,
        programSigning: SigningInfo? = nil, programPresence: Presence = .unknown, configFileMode: UInt16? = nil,
        source: SourceID = .agents, transportFingerprint: SecretFingerprint? = nil, hasHiddenScript: Bool = false
    ) {
        self.toolID = toolID
        self.toolName = toolName
        self.configPath = configPath
        self.registryPath = registryPath
        self.scope = scope
        self.name = name
        self.transport = transport
        self.environmentKeys = environmentKeys
        self.headerKeys = headerKeys
        self.isEnabled = isEnabled
        self.packageSource = packageSource
        self.hasSecretInArguments = hasSecretInArguments
        self.programSigning = programSigning
        self.programPresence = programPresence
        self.configFileMode = configFileMode
        self.source = source
        self.transportFingerprint = transportFingerprint
        self.hasHiddenScript = hasHiddenScript
    }

    /// Identität laut #129: Tool + Datei + Geltungsbereich + Servername, davor die Art des Eintrags (`mcp`). Sie trennt
    /// Server von Freigaben: Codex kennt `[mcp_servers.approval_policy]` und `approval_policy = "never"` in derselben
    /// Datei, und beide sollen sich nicht gegenseitig verdecken. `RecordIdentity` maskiert Trennzeichen.
    public var id: String { reference.entryID }

    /// Was einen Server in seiner Datei bestimmt – für Änderungen und Belege (Stufe 2).
    public var reference: AgentServerReference {
        AgentServerReference(toolID: toolID, toolName: toolName, configPath: configPath, registryPath: registryPath,
                             scope: scope, name: name)
    }

    /// Signifikant sind nur `transport` (Befehl, Argumente, URL, Art), sein Fingerabdruck (`transportFingerprint`) und
    /// `isEnabled`. Dabei ist `nil` (Format ohne Schalter bzw. Freigabe ausstehend) von `true` (aktiv) verschieden.
    /// Namen von Umgebungsvariablen und Headern, abgeleitete Angaben (Paketquelle, Geheimnis-Hinweis, Signatur,
    /// Vorhandensein), Dateirechte und die Registrierungsdatei zählen nicht. Ein neuer, fehlender oder mit anderem
    /// Schlüssel gebildeter Fingerabdruck zählt, damit der Snapshot gespeichert wird; gemeldet wird nur ein
    /// vergleichbarer Unterschied (`reportsChange(to:)`).
    public func hasSignificantChanges(comparedTo other: MCPServerEntry) -> Bool {
        hasReportableChanges(comparedTo: other) || transport != other.transport
            || transportFingerprint != other.transportFingerprint || hasHiddenScript != other.hasHiddenScript
    }

    /// Wie `hasSignificantChanges`, der Fingerabdruck zählt aber nur, wenn beide bekannt und vergleichbar sind
    /// (`SecretFingerprint.reportablyDiffers`): Ältere Snapshots ohne ihn lösen kein Ereignis aus.
    public func reportsChange(to other: MCPServerEntry) -> Bool {
        hasReportableChanges(comparedTo: other)
    }

    /// Derselbe Transport im strengen Sinn – Vorbedingung vor dem Bearbeiten (`AgentConfigEditor`): gleicher
    /// maskierter Transport und gleicher Fingerabdruck. Ein fehlender oder mit anderem Schlüssel gebildeter
    /// Fingerabdruck auf einer Seite gilt als verschieden – bei Verborgenem lieber neu scannen als blind ändern.
    public func hasSameTransport(as other: MCPServerEntry) -> Bool {
        transport == other.transport && transportFingerprint == other.transportFingerprint
    }

    /// Gleicher (maskierter) Transport, aber ein anderes verborgenes Geheimnis bzw. Skript.
    public func secretTransportDiffers(from other: MCPServerEntry) -> Bool {
        transport == other.transport && SecretFingerprint.reportablyDiffers(transportFingerprint, other.transportFingerprint)
    }

    /// Ob sich der sichtbare Transport geändert hat. Fehlt einer Seite der Fingerabdruck – ein Eintrag von vor #137 oder
    /// einer ohne Maskierung –, werden beide mit der heutigen Maskierung verglichen (`MCPTransport.remasked`): Ein früher
    /// teilmaskiertes Skript (`export GITHUB_TOKEN=••• && …`) gilt dann als dasselbe wie das heute ganz verborgene.
    public func transportDiffers(from other: MCPServerEntry) -> Bool {
        guard transport != other.transport else { return false }
        guard transportFingerprint == nil || other.transportFingerprint == nil else { return true }
        return transport.remasked != other.transport.remasked
    }

    /// Der Transport, wie er angezeigt, verglichen und kopiert wird: mit der heutigen Maskierung normalisiert
    /// (`MCPTransport.remasked`), auch bei vorhandenem Fingerabdruck. Gespeicherte Einträge kommen schon so herein
    /// (`init(from:)`); `CommandChange` nutzt es für Einträge, die nicht aus dem Speicher stammen.
    public var normalizedTransport: MCPTransport {
        transport.remasked
    }

    private func hasReportableChanges(comparedTo other: MCPServerEntry) -> Bool {
        transportDiffers(from: other) || isEnabled != other.isEnabled || secretTransportDiffers(from: other)
    }

    /// `MCPTransport.commandLine` bzw. die URL in einer Zeile: Whitespace-Läufe (auch Zeilenumbrüche und Tabs) werden
    /// vor dem Kürzen zu einem Leerzeichen, danach auf `summaryLength` Zeichen gekürzt.
    public var summary: String {
        let text = switch transport {
        case .local: transport.commandLine ?? ""
        case .remote(let url, _): url
        }
        let singleLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return singleLine.count > Self.summaryLength ? String(singleLine.prefix(Self.summaryLength - 1)) + "…" : singleLine
    }

    /// „Claude Desktop“, „Claude Code (Projekt web)“, „Claude Code (verwaltet)“.
    public var locationDescription: String { toolName + scope.displaySuffix }

    /// Zustand des Schalters: „aktiviert“/„deaktiviert“ (`nil`, wenn das Format keinen kennt); bei Servern aus
    /// Projektdateien „freigegeben“/„abgelehnt“/„Freigabe ausstehend“.
    public var enabledText: String? {
        guard registryPath != nil else { return isEnabled.map { $0 ? "aktiviert" : "deaktiviert" } }
        return isEnabled.map { $0 ? "freigegeben" : "abgelehnt" } ?? "Freigabe ausstehend"
    }
}

extension MCPServerEntry {
    private enum CodingKeys: String, CodingKey {
        case toolID, toolName, configPath, registryPath, scope, name, transport, environmentKeys, headerKeys, isEnabled
        case packageSource, hasSecretInArguments, transportFingerprint, programSigning, programPresence, configFileMode
        case source
        case hasHiddenScript
    }

    /// Liest gespeicherte Einträge. Auch mit `transportFingerprint` (ab #137) wird der
    /// Transport mit der heutigen Maskierung normalisiert (`MCPTransport.remasked`): Ein früher teilmaskiertes Skript
    /// (`export GITHUB_TOKEN=••• && …`) erreicht so weder Anzeige noch Vorher/Nachher, Verlauf, Benachrichtigung oder
    /// Kopie – an genau dieser einen Stelle, über die alle gespeicherten Daten hereinkommen. Für Einträge ohne
    /// Maskierung ändert das nichts (der Redactor ist auf seinen eigenen Ausgaben stabil).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolID = try container.decode(String.self, forKey: .toolID)
        toolName = try container.decode(String.self, forKey: .toolName)
        configPath = try container.decode(String.self, forKey: .configPath)
        registryPath = try container.decodeIfPresent(String.self, forKey: .registryPath)
        scope = try container.decode(AgentScope.self, forKey: .scope)
        name = try container.decode(String.self, forKey: .name)
        environmentKeys = try container.decode([String].self, forKey: .environmentKeys)
        headerKeys = try container.decode([String].self, forKey: .headerKeys)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
        packageSource = try container.decode(PackageSource.self, forKey: .packageSource)
        hasSecretInArguments = try container.decode(Bool.self, forKey: .hasSecretInArguments)
        transportFingerprint = try container.decodeIfPresent(SecretFingerprint.self, forKey: .transportFingerprint)
        programSigning = try container.decodeIfPresent(SigningInfo.self, forKey: .programSigning)
        programPresence = try container.decode(Presence.self, forKey: .programPresence)
        configFileMode = try container.decodeIfPresent(UInt16.self, forKey: .configFileMode)
        source = try container.decode(SourceID.self, forKey: .source)
        transport = try container.decode(MCPTransport.self, forKey: .transport)
        hasHiddenScript = try container.decodeIfPresent(Bool.self, forKey: .hasHiddenScript) ?? false
        if case .local(let command, let arguments) = transport {
            let redacted = ArgumentRedactor.redactStored(arguments: [command] + arguments,
                                                        hasScriptClassification: container.contains(.hasHiddenScript))
            hasHiddenScript = hasHiddenScript || redacted.hasHiddenScript
            transport = .local(command: redacted.values.first ?? command, arguments: Array(redacted.values.dropFirst()))
        } else {
            transport = normalizedTransport
        }
    }
}
