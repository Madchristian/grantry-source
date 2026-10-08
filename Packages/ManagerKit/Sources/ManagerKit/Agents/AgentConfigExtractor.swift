/// Ergebnis der Extraktion aus einem Dokument.
struct AgentExtraction: Equatable {
    var servers: [MCPServerEntry] = []
    var approvals: [AgentAutoApproval] = []
    /// Unerwartete Struktur im Klartext – nennt Datei, Bereich, Schlüssel und Servernamen, nie Werte.
    var problems: [String] = []
    /// Von der Datei registrierte Projekte (nur bei `ProjectLocation`).
    var projects: [AgentProject] = []
}

/// Ein registriertes Projekt samt seinem Objekt in der Registerdatei.
struct AgentProject: Equatable {
    let path: String
    let settings: ConfigValue
}

/// Wandelt einen geparsten `ConfigValue` anhand des Katalogeintrags in Einträge um (Spec §4). Interpreterpfade werden für die Maskierung aufgelöst;
/// Signaturen ergänzt `AgentConfigSource`.
enum AgentConfigExtractor {
    /// Höchstlänge eines Servernamens in Problemtexten, einschließlich „…“.
    static let problemNameLength = 60
    /// Werte von `ServerShape.transportPaths`, bei denen eine URL Vorrang vor einem zugleich angegebenen Befehl hat.
    private static let remoteKinds: Set<String> = ["http", "sse", "streamable-http"]

    /// Gemeinsame Angaben aller Einträge eines Durchgangs.
    private struct Context {
        let tool: AgentToolDefinition
        let configPath: String
        let registryPath: String?
        let scope: AgentScope
        let shape: ServerShape
        /// Schlüssel der Transport-Fingerabdrücke (`MCPServerEntry.transportFingerprint`).
        let fingerprinter: SecretFingerprinter

        /// Derselbe Durchgang für ein registriertes Projekt.
        func project(_ path: String) -> Context {
            Context(tool: tool, configPath: configPath, registryPath: registryPath, scope: .project(path: path), shape: shape,
                    fingerprinter: fingerprinter)
        }

        /// „.mcp.json (Projekt web): text“ – Dateiname und Bereich (beide über `displayName` gekürzt), nie Werte.
        func problem(_ text: String) -> String {
            let fileName = displayName(configPath.split(separator: "/").last.map(String.init) ?? configPath)
            let label = scope.scopeLabel.map { " (\(displayName($0)))" } ?? ""
            return fileName + label + ": " + text
        }
    }

    /// Server und Freigaben einer Katalogdatei samt der von ihr registrierten Projekte (`AgentConfigFile.projects`).
    /// Server in Projektobjekten gelten als aktiv, solange sie nicht in der Liste abgeschalteter Namen stehen.
    ///
    /// - Parameter fingerprinter: Schlüssel der Transport-Fingerabdrücke; der Scan übergibt den dauerhaften, Vergleiche
    ///   innerhalb des Prozesses (Inhalts-Stempel, Bearbeiten) genügt der prozesslokale.
    static func extract(
        _ document: ConfigValue, file: AgentConfigFile, tool: AgentToolDefinition, configPath: String,
        fingerprinter: SecretFingerprinter = .processLocal
    ) -> AgentExtraction {
        let context = Context(tool: tool, configPath: configPath, registryPath: nil,
                              scope: file.scope == .system ? .system : .user, shape: file.shape, fingerprinter: fingerprinter)
        var result = AgentExtraction()
        collectServers(at: file.serverPaths, in: document, context: context, isEnabled: { _ in nil }, into: &result)
        result.approvals += approvals(file.autoApprovals, in: document, context: context)
        if let location = file.projects {
            collectProjects(location, in: document, context: context, into: &result)
        }
        return result
    }

    /// Server einer Projektdatei (`<Projekt>/.mcp.json`); freigegeben bzw. abgelehnt laut `approvalState`
    /// (Projektobjekt und Einstellungsdateien des Projekts).
    ///
    /// Projektdateien haben heute kein Format mit Schalter (`ServerShape.standard`); `isEnabled == nil` bedeutet hier
    /// daher „Freigabe ausstehend“. Bekäme eine Projektdatei ein Format mit Schalter, würde
    /// `isEnabled(name) ?? enabledState(…)` einen ausstehenden Server als `true` führen – dann muss die Freigabe
    /// Vorrang vor dem Schalter-Standard bekommen.
    static func extractProjectFile(
        _ document: ConfigValue, projectFile: ProjectFile, projectPath: String, approvalState: ProjectApprovalState,
        tool: AgentToolDefinition, configPath: String, registryPath: String, shape: ServerShape,
        fingerprinter: SecretFingerprinter = .processLocal
    ) -> AgentExtraction {
        let context = Context(tool: tool, configPath: configPath, registryPath: registryPath,
                              scope: .project(path: projectPath), shape: shape, fingerprinter: fingerprinter)
        var result = AgentExtraction()
        collectServers(at: projectFile.serverPaths, in: document, context: context, isEnabled: approvalState.isEnabled,
                       into: &result)
        return result
    }

    /// Dateiweite Freigaben einer Einstellungsdatei im Projektordner (`<Projekt>/.claude/settings.json`) mit
    /// Projekt-Bereich. Server liest sie nicht; ihre Namenslisten wertet `ProjectApprovalState` aus.
    /// - Parameter registryPath: Datei, die das Projekt registriert – damit die Freigaben fortgeschrieben werden, wenn
    ///   sie nicht lesbar ist.
    static func extractProjectSettings(
        _ document: ConfigValue, settingsFile: ProjectSettingsFile, projectPath: String, tool: AgentToolDefinition,
        configPath: String, registryPath: String
    ) -> AgentExtraction {
        let context = Context(tool: tool, configPath: configPath, registryPath: registryPath,
                              scope: .project(path: projectPath), shape: .standard, fingerprinter: .processLocal)
        return AgentExtraction(approvals: approvals(settingsFile.autoApprovals, in: document, context: context))
    }

    // MARK: Projekte

    /// Server und Freigaben je Projektobjekt; Projekte, die kein Objekt sind, werden als Problem gemeldet. Projektpfade
    /// ohne abschließenden `/`; ein doppelt registriertes Projekt (`/x` und `/x/`) zählt einmal – das erste.
    private static func collectProjects(
        _ location: ProjectLocation, in document: ConfigValue, context: Context, into result: inout AgentExtraction
    ) {
        guard let container = document.value(at: location.projectsPath) else { return }
        guard let registry = container.object else {
            result.problems.append(context.problem("„\(displayName(location.projectsPath.joined(separator: ".")))“ ist kein Objekt"))
            return
        }
        var seen = Set<String>()
        for key in registry.keys {
            guard let settings = registry[key], settings.object != nil else {
                result.problems.append(context.problem("Projekt „\(displayName(key))“ ist kein Objekt"))
                continue
            }
            let path = projectPath(forKey: key)
            guard seen.insert(path).inserted else { continue }
            let projectContext = context.project(path)
            let disabled = Set(settings.strings(at: location.disabledNamesPath))
            collectServers(at: location.serverPaths, in: settings, context: projectContext,
                           isEnabled: { !disabled.contains($0) }, into: &result)
            result.approvals += approvals(location.autoApprovals, in: settings, context: projectContext)
            result.projects.append(AgentProject(path: path, settings: settings))
        }
    }

    /// Projektpfad zu einem Schlüssel der Registerdatei: `/p/web/` ist dasselbe Projekt wie `/p/web` – ohne
    /// abschließenden `/` (außer `/`). Kommt ein Projekt doppelt vor, gilt der erste Schlüssel.
    static func projectPath(forKey key: String) -> String {
        let trimmed = PathDisplay.trimmingTrailingSlashes(key)
        return trimmed.isEmpty ? key : trimmed
    }

    // MARK: Server

    /// Server unter allen `paths` eines Durchgangs. Kommt ein Name mehrfach vor (`mcp.servers` und `mcp` → `servers`),
    /// gilt der erste; die weiteren werden als Problem gemeldet.
    /// - Parameter isEnabled: Vorgabe von außen (Namenslisten); `nil` → Schalter laut `ServerShape.enabledField`.
    private static func collectServers(
        at paths: [[String]], in document: ConfigValue, context: Context, isEnabled: (String) -> Bool?,
        into result: inout AgentExtraction
    ) {
        var seen = Set<String>()
        for path in paths {
            guard let container = document.value(at: path) else { continue }
            guard let servers = container.object else {
                result.problems.append(context.problem("„\(displayName(path.joined(separator: ".")))“ ist kein Objekt"))
                continue
            }
            for name in servers.keys {
                guard seen.insert(name).inserted else {
                    result.problems.append(context.problem("Eintrag „\(displayName(name))“ mehrfach"))
                    continue
                }
                guard let value = servers[name], value.object != nil else {
                    result.problems.append(context.problem("Eintrag „\(displayName(name))“ ist kein Objekt"))
                    continue
                }
                guard let endpoint = endpoint(of: value, shape: context.shape, fingerprinter: context.fingerprinter) else {
                    if !isProvidedByExtension(value, shape: context.shape) {
                        result.problems.append(context.problem("Eintrag „\(displayName(name))“ hat weder Befehl noch URL"))
                    }
                    continue
                }
                result.servers.append(MCPServerEntry(
                    toolID: context.tool.id, toolName: context.tool.displayName, configPath: context.configPath,
                    registryPath: context.registryPath, scope: context.scope, name: name, transport: endpoint.transport,
                    environmentKeys: keys(at: context.shape.environmentPaths, in: value),
                    headerKeys: keys(at: context.shape.headerPaths, in: value),
                    isEnabled: isEnabled(name) ?? enabledState(of: value, field: context.shape.enabledField),
                    packageSource: endpoint.packageSource,
                    hasSecretInArguments: endpoint.containsSecret || hasCredential(value, shape: context.shape),
                    transportFingerprint: endpoint.fingerprint, hasHiddenScript: endpoint.hasHiddenScript
                ))
                result.approvals += approvals(context.shape.serverApprovals, in: value, context: context,
                                              settingPrefix: path + [name])
            }
        }
    }

    private struct Endpoint {
        let transport: MCPTransport
        let packageSource: PackageSource
        let containsSecret: Bool
        /// Fingerabdruck des unmaskierten Transports, falls etwas maskiert wurde.
        let fingerprint: SecretFingerprint?
        var hasHiddenScript: Bool = false
    }

    /// `unmaskedTransport`, maskiert: Befehl und Argumente gehen wie bei launchd durch `MaskedCommand`, die URL durch den
    /// `ArgumentRedactor`; was maskiert wurde, hält ein Fingerabdruck der Rohwerte fest.
    private static func endpoint(of server: ConfigValue, shape: ServerShape, fingerprinter: SecretFingerprinter) -> Endpoint? {
        switch unmaskedTransport(of: server, shape: shape) {
        case .remote(let url, let kind)?:
            let redacted = ArgumentRedactor.redact(url: url)
            let transport = MCPTransport.remote(url: redacted.value, kind: kind)
            return Endpoint(transport: transport, packageSource: .remote(host: transport.remoteHost ?? ""),
                            containsSecret: redacted.containsSecret,
                            fingerprint: redacted.value == url ? nil : fingerprinter.fingerprint(of: [url]))
        case .local(let command, let arguments)?:
            // Der Befehl wird mitmaskiert (`sh -c 'export TOKEN=…'`); er ist hier `argv[0]` und zugleich das Programm.
            let masked = MaskedCommand(program: nil, arguments: [command] + arguments, fingerprinter: fingerprinter)
            let maskedCommand = masked.program ?? ArgumentRedactor.mask
            let maskedArguments = Array(masked.arguments.dropFirst())
            return Endpoint(
                transport: .local(command: maskedCommand, arguments: maskedArguments),
                packageSource: PackageSourceDetector.detect(command: maskedCommand, arguments: maskedArguments),
                containsSecret: masked.containsSecret, fingerprint: masked.fingerprint, hasHiddenScript: masked.hasHiddenScript
            )
        case nil:
            return nil
        }
    }

    /// Transport des Servers, wie er in der Datei steht – unmaskiert: lokal, wenn ein Befehl da ist, sonst entfernt,
    /// wenn eine URL da ist; nennt die Art `http`, `sse` oder `streamable-http`, hat die URL Vorrang. `nil` ohne beides.
    /// Nur Zwischenschritt für `endpoint` – Snapshots bekommen den maskierten Transport.
    private static func unmaskedTransport(of server: ConfigValue, shape: ServerShape) -> MCPTransport? {
        let command = firstString(at: shape.commandPaths, in: server)
        let kind = firstString(at: shape.transportPaths, in: server)
        if let url = firstString(at: shape.urlPaths, in: server),
           command == nil || kind.map({ remoteKinds.contains($0.lowercased()) }) == true {
            return .remote(url: url, kind: kind)
        }
        guard let command else { return nil }
        // Nicht-skalare Argumente (null, Objekt, Liste) startet kein Tool sinnvoll – sie werden weggelassen.
        let arguments = shape.argumentPaths.lazy.compactMap { server.value(at: $0)?.array }.first ?? []
        return .local(command: command, arguments: arguments.compactMap(\.scalarText))
    }

    /// Server, den laut `ServerShape.extensionMarkers` eine Erweiterung des Tools bereitstellt.
    private static func isProvidedByExtension(_ server: ConfigValue, shape: ServerShape) -> Bool {
        shape.extensionMarkers.contains { marker in
            switch marker {
            case .value(let path, let expected): server.value(at: path)?.scalarText == expected
            case .onlyKeys(let keys): server.object.map { !$0.keys.isEmpty && Set($0.keys).isSubset(of: keys) } == true
            }
        }
    }

    /// Ein Schlüssel aus `ServerShape.credentialPaths` ist vorhanden – sein (geschwärzter) Wert ist unbekannt.
    private static func hasCredential(_ server: ConfigValue, shape: ServerShape) -> Bool {
        shape.credentialPaths.contains { server.value(at: $0) != nil }
    }

    /// Kennt das Format einen Schalter, gilt ein fehlender als „aktiv“ (`true`) – sonst meldete das Ergänzen von
    /// `"disabled": false` eine Schein-Änderung. `nil` nur, wenn das Format keinen Schalter kennt.
    private static func enabledState(of server: ConfigValue, field: ServerShape.EnabledField?) -> Bool? {
        switch field {
        case .enabled(let path): server.value(at: path)?.bool ?? true
        case .disabled(let path): !(server.value(at: path)?.bool ?? false)
        case nil: nil
        }
    }

    // MARK: Freigaben

    private static func approvals(
        _ rules: [AutoApprovalRule], in document: ConfigValue, context: Context, settingPrefix: [String] = []
    ) -> [AgentAutoApproval] {
        rules.compactMap { rule in
            guard let value = document.value(at: rule.path)?.scalarText, rule.triggers.contains(value) else { return nil }
            return AgentAutoApproval(
                toolID: context.tool.id, toolName: context.tool.displayName, configPath: context.configPath,
                registryPath: context.registryPath, scope: context.scope, setting: (settingPrefix + rule.path).joined(separator: "."), value: value,
                message: rule.message
            )
        }
    }

    // MARK: Hilfen

    /// Erster nicht leerer String unter `paths`; nur aus Leerraum bestehende Strings zählen als fehlend.
    private static func firstString(at paths: [[String]], in value: ConfigValue) -> String? {
        paths.lazy.compactMap { value.value(at: $0)?.string }.first { !$0.allSatisfy(\.isWhitespace) }
    }

    /// Schlüsselnamen aller Objekte unter `paths`, ohne Dubletten, in Dokumentreihenfolge.
    private static func keys(at paths: [[String]], in value: ConfigValue) -> [String] {
        var seen = Set<String>()
        return paths.flatMap { value.value(at: $0)?.object?.keys ?? [] }.filter { seen.insert($0).inserted }
    }

    /// Name für Problemtexte: Whitespace-Läufe werden zu einem Leerzeichen, danach auf `problemNameLength` Zeichen
    /// gekürzt (mit „…“).
    static func displayName(_ name: String) -> String {
        let singleLine = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard singleLine.count > problemNameLength else { return singleLine }
        return String(singleLine.prefix(problemNameLength - 1)) + "…"
    }
}
