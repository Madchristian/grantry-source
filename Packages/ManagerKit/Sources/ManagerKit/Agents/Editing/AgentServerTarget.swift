import Foundation

/// Was einen MCP-Server in seiner Datei bestimmt (Stufe 2) – die Teile der Identität (`MCPServerEntry.id`) plus der
/// Tool-Name für Texte. Steht in Belegen (`AgentConfigChange`); die Fallnamen sind Teil des Belegformats.
public struct AgentServerReference: Codable, Hashable, Sendable {
    public let toolID: String
    public let toolName: String
    public let configPath: String
    public let registryPath: String?
    public let scope: AgentScope
    public let name: String

    public init(toolID: String, toolName: String, configPath: String, registryPath: String?, scope: AgentScope, name: String) {
        self.toolID = toolID
        self.toolName = toolName
        self.configPath = configPath
        self.registryPath = registryPath
        self.scope = scope
        self.name = name
    }

    /// `MCPServerEntry.id` des Servers.
    public var entryID: String { RecordIdentity.join(["mcp", toolID, configPath, scope.identityComponent, name]) }

    /// „Claude Code (Projekt web)“.
    public var locationDescription: String { toolName + scope.displaySuffix }
}

/// Wo ein Server in seiner Datei steht und wie er sich schalten lässt – abgeleitet aus dem Katalog, gesucht im frisch
/// gelesenen Dokument (Stufe 2). Rein.
struct AgentServerTarget: Sendable {
    /// Wie das Format einen Server abschaltet.
    enum Switch: Hashable, Sendable {
        /// Bool im Server-Objekt; `inverted`: `true` heißt abgeschaltet (`disabled`).
        case field(key: String, inverted: Bool)
        /// Namensliste im Projektobjekt der Registerdatei (Claude Code `disabledMcpServers`), relativ zum Projektobjekt.
        case disabledNames([String])
    }

    let reference: AgentServerReference
    let tool: AgentToolDefinition
    /// Katalogdatei: die Datei selbst bzw. bei Servern aus Projektdateien die Registerdatei.
    let file: AgentConfigFile
    /// Nur bei Servern aus Projektdateien (`.mcp.json`).
    let projectFile: ProjectFile?
    let syntax: ConfigSyntax
    let redaction: ConfigRedaction
    /// `nil`, wenn das Format für diesen Server keinen Schalter kennt.
    let switchKind: Switch?

    /// Sucht Tool und Datei des Servers im Katalog; `notEditable`, wenn Grantry sie nicht kennt oder sie verwaltet ist
    /// (Bereich `.system` – zusätzlich zur Sperre in `AgentEditCapabilities`).
    init(reference: AgentServerReference, catalog: AgentToolCatalog, home: String) throws(AgentConfigEditError) {
        guard reference.scope != .system else { throw .notEditable("Verwaltete Konfigurationen ändert Grantry nicht") }
        guard let tool = catalog.tool(id: reference.toolID) else { throw .notEditable("Das Tool ist Grantry nicht bekannt") }
        self.reference = reference
        self.tool = tool
        if let registryPath = reference.registryPath {
            guard case .project(let projectPath) = reference.scope,
                  let file = tool.files.first(where: { $0.expandedPath(home: home) == registryPath && $0.projects?.projectFile != nil }),
                  let projectFile = file.projects?.projectFile,
                  reference.configPath == (projectPath as NSString).appendingPathComponent(projectFile.relativePath)
            else { throw .notEditable("Die Datei ist Grantry nicht bekannt") }
            self.file = file
            self.projectFile = projectFile
            syntax = projectFile.syntax
            redaction = projectFile.redaction
            switchKind = nil
            return
        }
        guard let file = tool.files.first(where: { candidate in
            candidate.expandedPath(home: home) == reference.configPath && candidate.scope != .system
        }) else { throw .notEditable("Die Datei ist Grantry nicht bekannt") }
        self.file = file
        projectFile = nil
        syntax = file.syntax
        redaction = file.redaction
        // `.system` ist oben schon abgelehnt; hier bleiben Projekt- und Benutzerbereich.
        if case .project = reference.scope {
            guard let location = file.projects else { throw .notEditable("Die Datei ist Grantry nicht bekannt") }
            switchKind = location.disabledNamesPath.map(Switch.disabledNames)
            return
        }
        switchKind = switch file.shape.enabledField {
        case .enabled(let path) where path.count == 1: .field(key: path[0], inverted: false)
        case .disabled(let path) where path.count == 1: .field(key: path[0], inverted: true)
        default: nil
        }
    }

    /// Pfad des Projektobjekts in der Registerdatei (erster Schlüssel, der zum Projekt gehört – wie die Extraktion);
    /// `nil` für Server außerhalb von Projektobjekten.
    func projectObjectPath(in document: ConfigValue) -> [String]? {
        guard reference.registryPath == nil, let location = file.projects, let key = projectKey(in: document) else { return nil }
        return location.projectsPath + [key]
    }

    /// Ob die Registerdatei (`registry`: ihr Inhalt, frisch gelesen) das Projekt des Servers enthält; außerhalb von
    /// Projekten immer `true`. Ein Beleg nennt sein Projekt selbst – geändert wird nur in Projekten, die das Tool kennt.
    func isProjectRegistered(in registry: Data) throws(AgentConfigEditError) -> Bool {
        guard case .project = reference.scope else { return true }
        let tree = try AgentConfigEditError.parsing { () throws(ConfigParseError) in
            try ConfigParsing.parse(registry, syntax: file.syntax, redaction: file.redaction)
        }
        return projectKey(in: tree) != nil
    }

    /// Erster Schlüssel der Registerdatei, der zum Projekt des Servers gehört (wie die Extraktion).
    private func projectKey(in document: ConfigValue) -> String? {
        guard case .project(let projectPath) = reference.scope, let location = file.projects else { return nil }
        return document.value(at: location.projectsPath)?.object?.keys
            .first { AgentConfigExtractor.projectPath(forKey: $0) == projectPath }
    }

    /// Voller Pfad des Server-Objekts: die Server-Liste, die den Namen enthält; `nil`, wenn er fehlt. Steht der Name in
    /// mehreren Listen (VS Code: `mcp.servers` und `mcp` → `servers`), zeigt der Scan die erste – geändert wird keine
    /// (`unsupportedLayout`), die Nachprüfung könnte die andere sonst nicht von einer Nebenwirkung unterscheiden.
    func serverPath(in document: ConfigValue) throws(AgentConfigEditError) -> [String]? {
        let containing = serverLists(in: document).filter { document.value(at: $0)?.object?[reference.name] != nil }
        guard containing.count <= 1 else { throw .unsupportedLayout }
        return containing.first.map { $0 + [reference.name] }
    }

    /// Pfade der Server-Listen, in denen der Server stehen kann; leer, wenn sein Projekt fehlt.
    func serverLists(in document: ConfigValue) -> [[String]] {
        if let projectFile { return projectFile.serverPaths }
        guard case .project = reference.scope else { return file.serverPaths }
        guard let project = projectObjectPath(in: document), let location = file.projects else { return [] }
        return location.serverPaths.map { project + $0 }
    }

    /// Der Server, wie die Extraktion ihn aus `document` liest; `nil`, wenn er fehlt. Die Freigabe von Servern aus
    /// Projektdateien bleibt hier offen – verglichen wird nur, was die Datei selbst bestimmt.
    /// - Parameter fingerprinter: derselbe Schlüssel wie im Scan, damit `MCPServerEntry.transportFingerprint`
    ///   vergleichbar ist.
    func currentEntry(in document: ConfigValue, fingerprinter: SecretFingerprinter = .processLocal) -> MCPServerEntry? {
        let extraction: AgentExtraction
        if let projectFile, let registryPath = reference.registryPath, case .project(let projectPath) = reference.scope {
            extraction = AgentConfigExtractor.extractProjectFile(
                document, projectFile: projectFile, projectPath: projectPath, approvalState: ProjectApprovalState(),
                tool: tool, configPath: reference.configPath, registryPath: registryPath, shape: file.shape,
                fingerprinter: fingerprinter
            )
        } else {
            extraction = AgentConfigExtractor.extract(
                document, file: file, tool: tool, configPath: reference.configPath, fingerprinter: fingerprinter
            )
        }
        return extraction.servers.first { $0.id == reference.entryID }
    }
}
