import Foundation
import Synchronization

/// Scan-Quelle der Agenten-Konfigurationen (Spec §3/§4, `SourceID.agents`).
///
/// Liest jede Katalogdatei über `AgentConfigReader`, parst sie mit Schwärzung (`AgentConfigFile.redaction`) und
/// extrahiert Server und Freigaben (`AgentConfigExtractor`). Projektdateien und Projekt-Einstellungsdateien nur für
/// Projekte, die die Datei selbst registriert (kein Durchsuchen von Ordnern); sie werden nicht überwacht, sondern bei
/// jedem Scan gelesen. Lokale Programme bekommen Vorhandensein, direkt gestartete Programme
/// (kein Skript) zusätzlich ihre Signatur.
///
/// - Fehlt eine Datei, ist das kein Befund.
/// - Ist sie nicht lesbar oder nicht parsebar: Einschränkung „Konfiguration von … nicht lesbar (…)“ und Eintrag in
///   `AgentContribution.incompleteFiles` – ihre Einträge werden fortgeschrieben, statt als entfernt zu gelten.
/// - Unerwartete Struktur einzelner Einträge: Einschränkung, der Rest der Datei zählt normal.
/// - Projekte auf einem nicht eingehängten Volume (`/Volumes/<name>` fehlt): Lücke ohne Einschränkung – ihre Einträge
///   werden fortgeschrieben, An- und Abstecken erzeugt keine Schein-Änderungen.
/// - Projekte auf einem Netzlaufwerk (ohne `MNT_LOCAL`) werden nicht gelesen (ein hängender Server hielte den Scan an):
///   Lücke und eine Einschränkung je Volume. Programme dort (oder auf einem nicht eingehängten Volume) werden nicht
///   geprüft: Vorhandensein unbekannt.
/// - Gesammelt wird auf einer eigenen seriellen Queue (Signaturprüfungen können bis zu ihrer Frist warten).
public struct AgentConfigSource: InventorySource {
    public let id = SourceID.agents

    private let catalog: AgentToolCatalog
    private let home: String
    private let inspector: any SigningInspecting
    private let volumes: @Sendable () -> [MountedVolume]
    private let fingerprinter: SecretFingerprinter
    private let queue = DispatchQueue(label: "de.cstrube.Grantry.agent-configs", qos: .utility)

    /// - Parameter fingerprinter: Schlüssel der Transport-Fingerabdrücke (`MCPServerEntry.transportFingerprint`); die
    ///   App übergibt den dauerhaften ihres Ablageorts (`StorageLocation.secretFingerprinter()`).
    public init(
        catalog: AgentToolCatalog = .standard, home: String = NSHomeDirectory(),
        inspector: any SigningInspecting = CachingSigningInspector(), fingerprinter: SecretFingerprinter = .processLocal
    ) {
        self.init(catalog: catalog, home: home, inspector: inspector, volumes: MountedVolume.current, fingerprinter: fingerprinter)
    }

    /// - Parameter volumes: Einhängepunkte, einmal pro Scan abgefragt (Tests übergeben feste Werte).
    init(
        catalog: AgentToolCatalog, home: String, inspector: any SigningInspecting,
        volumes: @escaping @Sendable () -> [MountedVolume], fingerprinter: SecretFingerprinter = .processLocal
    ) {
        self.catalog = catalog
        self.home = home
        self.inspector = inspector
        self.volumes = volumes
        self.fingerprinter = fingerprinter
    }

    public func collect() async throws -> InventoryContribution {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: scan()) }
        }
    }

    /// Statische Katalogpfade für die Dateiüberwachung (`ScanTriggers.files`).
    public static func watchedFiles(catalog: AgentToolCatalog = .standard, home: String = NSHomeDirectory()) -> [String] {
        catalog.staticPaths(home: home)
    }

    // MARK: Inhalts-Stempel

    /// Inhalts-Stempel aller Katalogdateien für `FSEventsWatcher(contentStamps:)` (Spec §6), geschlüsselt wie
    /// `watchedFiles`: Hash dessen, was der Scan aus der Datei macht – Server, Freigaben, Probleme, Einschränkungen,
    /// Dateirechte und registrierte Projekte samt deren Freigabelisten für die Projektdatei. Er ändert sich nicht bei
    /// Schreibvorgängen an anderen Schlüsseln (Statistiken in `~/.claude.json`) und nicht bei geänderten
    /// Geheimnis-Werten (die der Parser nie liest). Neu berechnet wird er nur bei geändertem Fingerabdruck des Ziels.
    ///
    /// Gehört ein Pfad mehreren Tools, zählt das erste – der Katalog schließt das aus
    /// (`AgentToolCatalogTests.noTwoToolsShareAStaticPath`).
    public static func contentStamps(
        catalog: AgentToolCatalog = .standard, home: String = NSHomeDirectory()
    ) -> [String: FSEventsWatcher.ContentStamp] {
        let stamper = ContentStamper(home: home)
        var stamps: [String: FSEventsWatcher.ContentStamp] = [:]
        for tool in catalog.tools {
            for file in tool.files where stamps[file.expandedPath(home: home)] == nil {
                stamps[file.expandedPath(home: home)] = { stamper.stamp(file, of: tool) }
            }
        }
        return stamps
    }

    /// Merkt sich je Datei Fingerabdruck (des Symlink-Ziels, wie `CachingSigningInspector`) und Stempel; gerechnet wird
    /// nur bei geändertem Fingerabdruck und außerhalb der Sperre.
    final class ContentStamper: Sendable {
        /// Rechnet den Stempel einer vorhandenen Datei (`contentStamp(of:tool:home:)`; Tests zählen Aufrufe).
        typealias Compute = @Sendable (AgentConfigFile, AgentToolDefinition, String) -> Int?

        private struct Entry {
            let fingerprint: FileFingerprint
            let stamp: Int?
        }

        private let home: String
        private let compute: Compute
        private let entries = Mutex<[String: Entry]>([:])

        init(home: String, compute: @escaping Compute = AgentConfigSource.contentStamp(of:tool:home:)) {
            self.home = home
            self.compute = compute
        }

        func stamp(_ file: AgentConfigFile, of tool: AgentToolDefinition) -> Int? {
            let path = file.expandedPath(home: home)
            guard let fingerprint = FileFingerprint(of: FileFingerprint.target(of: path)) else {
                entries.withLock { $0[path] = nil }
                return nil
            }
            if let entry = entries.withLock({ $0[path] }), entry.fingerprint == fingerprint { return entry.stamp }
            let stamp = compute(file, tool, home)
            entries.withLock { $0[path] = Entry(fingerprint: fingerprint, stamp: stamp) }
            return stamp
        }
    }

    /// Hash dessen, was der Scan aus der Datei macht (ohne Signaturen und Projektdateien); `nil`, wenn sie fehlt.
    /// Liest der Scan Projektdateien, zählen die registrierten Projekte mit – je Projekt sein Pfad und genau die
    /// Werte unter den Freigabe-Pfaden der `ProjectFile` (nicht Statistiken wie `lastCost` daneben). Ebenso zählen die
    /// globalen Namenslisten (`AgentConfigFile.projectServerApprovals`), da sie die Freigabe aller `.mcp.json`-Server
    /// mitbestimmen. Grenze: Projekt-Einstellungsdateien (`.claude/settings*.json`) und `.mcp.json` sind nicht
    /// überwacht – ihre Änderungen zeigt erst der nächste Scan.
    static func contentStamp(of file: AgentConfigFile, tool: AgentToolDefinition, home: String) -> Int? {
        let path = file.expandedPath(home: home)
        var collected = Collected()
        let outcome = load(path, as: file, tool: tool, home: AgentConfigReader.Home(home), into: &collected)
        if case .missing = outcome { return nil }
        var hasher = Hasher()
        if case .loaded(let loaded) = outcome {
            let extraction = AgentConfigExtractor.extract(loaded.document, file: file, tool: tool, configPath: path)
            hasher.combine(loaded.mode)
            hasher.combine(extraction.servers)
            hasher.combine(extraction.approvals)
            hasher.combine(extraction.problems)
            if let projectFile = file.projects?.projectFile {
                for project in extraction.projects {
                    hasher.combine(project.path)
                    hasher.combine(projectFile.approvalValues(in: project.settings))
                }
            }
            if let lists = file.projectServerApprovals {
                hasher.combine(lists.approvalValues(in: loaded.document))
            }
        }
        hasher.combine(collected.limitations)
        return hasher.finalize()
    }

    // MARK: Scan

    struct Collected {
        var servers: [MCPServerEntry] = []
        var approvals: [AgentAutoApproval] = []
        var limitations: [String] = []
        var gaps: [String] = []
        /// Netzlaufwerke, für die schon eine Einschränkung vorliegt.
        var notedNetworkVolumes: Set<String> = []
    }

    /// Was ein Scan einmal ermittelt und für alle Dateien nutzt.
    private struct ScanContext {
        let home: AgentConfigReader.Home
        let volumes: [MountedVolume]
    }

    private func scan() -> InventoryContribution {
        var collected = Collected()
        let context = ScanContext(home: AgentConfigReader.Home(home), volumes: volumes())
        for tool in catalog.tools {
            scan(tool, context: context, into: &collected)
        }
        let agents = AgentContribution(
            mcpServers: collected.servers.map { inspectingProgram($0, volumes: context.volumes) },
            agentAutoApprovals: collected.approvals, incompleteFiles: collected.gaps
        )
        return InventoryContribution(agents: agents, limitations: collected.limitations)
    }

    /// Eine Registerdatei mit den von ihr registrierten Projekten, deren Dateien erst nach allen Katalogdateien des
    /// Tools gelesen werden.
    private struct Registry {
        let file: AgentConfigFile
        let path: String
        let projects: [AgentProject]
    }

    /// Zwei Phasen: erst alle Katalogdateien des Tools (dabei die globalen Namenslisten sammeln), dann die Projekte
    /// der Registerdateien – deren `.mcp.json`-Freigabe hängt von den globalen Listen ab.
    private func scan(_ tool: AgentToolDefinition, context: ScanContext, into collected: inout Collected) {
        // `nil`: Eine Datei mit globalen Namenslisten war nicht lesbar – die Freigabe der Projektserver ist unbekannt.
        var sharedApprovals: ProjectApprovalState? = ProjectApprovalState()
        var registries: [Registry] = []
        for file in tool.files {
            let path = file.expandedPath(home: home)
            let outcome = Self.load(path, as: file, tool: tool, home: context.home, into: &collected)
            if outcome.isFailure, file.projectServerApprovals != nil { sharedApprovals = nil }
            guard let loaded = outcome.loaded else { continue }
            let extraction = AgentConfigExtractor.extract(
                loaded.document, file: file, tool: tool, configPath: path, fingerprinter: fingerprinter
            )
            absorb(extraction, mode: loaded.mode, tool: tool, into: &collected)
            if let lists = file.projectServerApprovals {
                sharedApprovals = sharedApprovals?.overlaid(with: loaded.document, paths: lists)
            }
            if file.projects != nil {
                registries.append(Registry(file: file, path: path, projects: extraction.projects))
            }
        }
        guard !registries.isEmpty else { return }
        let catalogFiles = CatalogFiles(tool.files.map { $0.expandedPath(home: home) })
        for registry in registries {
            guard let location = registry.file.projects else { continue }
            for project in registry.projects where project.path.hasPrefix("/") {
                scan(project, location: location, registryPath: registry.path, shape: registry.file.shape,
                     sharedApprovals: sharedApprovals, catalogFiles: catalogFiles, tool: tool, context: context,
                     into: &collected)
            }
        }
    }

    /// Statische Katalogpfade eines Tools, wie angegeben und aufgelöst. Eine Projektdatei, die auf eine davon fällt
    /// (Projekt = Home: `<home>/.claude/settings.json` ist `~/.claude/settings.json`), ist schon gelesen – ein zweites
    /// Lesen meldete jede Freigabe doppelt.
    private struct CatalogFiles {
        private let paths: Set<String>

        init(_ paths: [String]) {
            self.paths = Set(paths + paths.compactMap(AgentConfigReader.canonicalPath))
        }

        func contains(_ path: String) -> Bool {
            paths.contains(path) || AgentConfigReader.canonicalPath(path).map(paths.contains) == true
        }
    }

    /// Dateien eines registrierten Projekts: erst die Einstellungsdateien (Freigaben mit Projekt-Bereich, Namenslisten
    /// für die Projektdatei), dann die Projektdatei. Ist eine Einstellungsdatei nicht lesbar – oder eine globale
    /// (`sharedApprovals == nil`) –, ist die Freigabe der Server unbekannt: Dann wird die Projektdatei nicht gelesen,
    /// sondern als Lücke fortgeschrieben. Dateien, die auf eine Katalogdatei des Tools fallen (`catalogFiles`), entfallen.
    private func scan(
        _ project: AgentProject, location: ProjectLocation, registryPath: String, shape: ServerShape,
        sharedApprovals: ProjectApprovalState?, catalogFiles: CatalogFiles, tool: AgentToolDefinition,
        context: ScanContext, into collected: inout Collected
    ) {
        func path(_ relativePath: String) -> String { (project.path as NSString).appendingPathComponent(relativePath) }
        let projectFilePath = location.projectFile.map { path($0.relativePath) }
        let settingsPaths = location.settingsFiles.map { path($0.relativePath) }
        guard isReadable(project: project.path, files: [projectFilePath].compactMap(\.self) + settingsPaths,
                         volumes: context.volumes, into: &collected) else { return }
        var approvalState = sharedApprovals ?? ProjectApprovalState()
        if let projectFile = location.projectFile {
            approvalState = approvalState.overlaid(with: project.settings, paths: projectFile)
        }
        var settingsAreComplete = sharedApprovals != nil
        for (settingsFile, settingsPath) in zip(location.settingsFiles, settingsPaths)
        where !catalogFiles.contains(settingsPath) {
            let outcome = Self.load(settingsPath, as: settingsFile, tool: tool, home: context.home, into: &collected)
            if outcome.isFailure { settingsAreComplete = false }
            guard let loaded = outcome.loaded else { continue }
            approvalState = approvalState.overlaid(with: loaded.document, paths: settingsFile)
            let settingsExtraction = AgentConfigExtractor.extractProjectSettings(
                loaded.document, settingsFile: settingsFile, projectPath: project.path, tool: tool, configPath: settingsPath,
                registryPath: registryPath
            )
            absorb(settingsExtraction, mode: loaded.mode, tool: tool, into: &collected)
        }
        guard let projectFile = location.projectFile, let projectFilePath, !catalogFiles.contains(projectFilePath) else {
            return
        }
        guard settingsAreComplete else {
            collected.gaps.append(projectFilePath)
            return
        }
        guard let loaded = Self.load(projectFilePath, as: projectFile, tool: tool, home: context.home,
                                     into: &collected).loaded else { return }
        let projectExtraction = AgentConfigExtractor.extractProjectFile(
            loaded.document, projectFile: projectFile, projectPath: project.path, approvalState: approvalState, tool: tool,
            configPath: projectFilePath, registryPath: registryPath, shape: shape, fingerprinter: fingerprinter
        )
        absorb(projectExtraction, mode: loaded.mode, tool: tool, into: &collected)
    }

    /// `false` (und Lücke für alle `files`), wenn das Projekt auf einem Netzlaufwerk liegt – dann zusätzlich eine
    /// Einschränkung je Volume – oder auf einem nicht eingehängten Volume unter `/Volumes` (`Placement`).
    private func isReadable(
        project: String, files: [String], volumes: [MountedVolume], into collected: inout Collected
    ) -> Bool {
        switch Placement(of: project, volumes: volumes) {
        case .local:
            return true
        case .network(let volume):
            collected.gaps += files
            if collected.notedNetworkVolumes.insert(volume.path).inserted {
                collected.limitations.append("Projekte auf Netzlaufwerk \(volume.path) nicht gelesen")
            }
            return false
        case .unmounted:
            collected.gaps += files
            return false
        }
    }

    /// Wo ein Pfad liegt – entscheidet, ob der Scan ihn berühren darf.
    enum Placement: Equatable {
        /// Lokal (oder unbekanntes Volume) – wird normal gelesen.
        case local
        /// Auf einem Netzlaufwerk (ohne `MNT_LOCAL`): nicht berühren, ein hängender Server hielte den Scan an.
        case network(MountedVolume)
        /// Unter `/Volumes/<name>`, das nicht eingehängt ist (und der Pfad fehlt).
        case unmounted

        /// Netzlaufwerke werden nur anhand der Einhängetabelle erkannt, ohne ihr Dateisystem zu berühren; bei einem
        /// nicht eingehängten `/Volumes/<name>` wird nur der (lokale) Pfad auf dem Wurzel-Volume geprüft.
        init(of path: String, volumes: [MountedVolume]) {
            if let volume = MountedVolume.containing(path, in: volumes), !volume.isLocal {
                self = .network(volume)
            } else if let mountPoint = MountedVolume.volumesMountPoint(of: path),
                      !volumes.contains(where: { $0.path == mountPoint }), Presence(ofItemAt: path) == .missing {
                self = .unmounted
            } else {
                self = .local
            }
        }
    }

    struct Loaded {
        let document: ConfigValue
        let mode: UInt16
    }

    /// Ergebnis von `load`: Scan und Inhalts-Stempel lesen die Datei so nur einmal.
    enum LoadOutcome {
        case missing
        /// Leer (nur Leerraum oder BOM) – keine Konfiguration, kein Befund.
        case blank
        /// Nicht lesbar oder nicht parsebar – mit Einschränkung und Lücke.
        case failed
        case loaded(Loaded)

        var loaded: Loaded? {
            if case .loaded(let loaded) = self { loaded } else { nil }
        }

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    /// Liest und parst `path`, wie `file` es beschreibt; ist die Datei nicht lesbar oder nicht parsebar, zusätzlich
    /// Einschränkung und Lücke.
    static func load(
        _ path: String, as file: some ParsedConfigFile, tool: AgentToolDefinition, home: AgentConfigReader.Home,
        into collected: inout Collected
    ) -> LoadOutcome {
        func failure(_ reason: String) {
            collected.limitations.append("Konfiguration von \(tool.displayName) nicht lesbar (\(path)): \(reason)")
            collected.gaps.append(path)
        }
        switch AgentConfigReader.read(path: path, home: home) {
        case .missing:
            return .missing
        case .unreadable(let reason):
            failure(reason)
            return .failed
        case .contents(let data, let mode):
            guard !ConfigParsing.isBlank(data) else { return .blank }
            do {
                let document = try ConfigParsing.parse(data, syntax: file.syntax, redaction: file.redaction)
                return .loaded(Loaded(document: document, mode: mode))
            } catch {
                failure(error.description)
                return .failed
            }
        }
    }

    private func absorb(_ extraction: AgentExtraction, mode: UInt16, tool: AgentToolDefinition, into collected: inout Collected) {
        collected.servers += extraction.servers.map { server in
            var server = server
            server.configFileMode = mode
            return server
        }
        collected.approvals += extraction.approvals
        collected.limitations += extraction.problems.map { "Konfiguration von \(tool.displayName): \($0)" }
    }

    /// Vorhandensein und Signatur eines lokalen Programms (nur absolute Pfade, nur prüfbare Dateien). Liegt es auf einem
    /// Netzlaufwerk oder einem nicht eingehängten Volume (`Placement`), bleibt beides unbekannt – ohne Dateizugriff.
    private func inspectingProgram(_ server: MCPServerEntry, volumes: [MountedVolume]) -> MCPServerEntry {
        guard case .localProgram(let path) = server.packageSource else { return server }
        var server = server
        guard Placement(of: path, volumes: volumes) == .local else {
            server.programPresence = .unknown
            return server
        }
        server.programPresence = Presence(ofItemAt: path)
        // Nur das gestartete Programm selbst, kein Skript: Skripte hinter `node`/`python3` oder mit `#!` tragen keine
        // Code-Signatur – „unsigniert“ wäre bei jedem lokalen Node-Server ein Fehlalarm.
        guard server.programPresence == .present, case .local(let command, _) = server.transport, command == path,
              ScriptFile.shebang(atPath: path) == nil, FileType.isSafeToInspect(atPath: path) else { return server }
        server.programSigning = inspector.inspect(path: path)
        return server
    }
}
