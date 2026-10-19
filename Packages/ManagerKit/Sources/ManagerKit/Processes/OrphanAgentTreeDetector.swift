import Darwin
import Foundation
import GrantryShared

/// Ein verwaister Agenten-Baum: Wurzel mit Elternprozess launchd und ihr ganzer Unterbaum (#221).
public struct AgentProcessTree: Identifiable, Hashable, Sendable {
    public let pattern: AgentProcessPattern
    /// Wurzel zuerst, dann der Unterbaum in Breitensuche – die Reihenfolge der Signale.
    public let members: [ProcessEntry]
    /// Arbeitsordner der Wurzel; `nil`, wenn nicht lesbar.
    public let workspace: String?

    public var root: ProcessEntry { members[0] }
    /// PID und Startzeit der Wurzel: bleibt über Scans gleich, solange es derselbe Prozess ist.
    public var id: String { "\(root.pid):\(root.startTime)" }
    public var processCount: Int { members.count }
    /// Summe des lesbaren Speichers.
    public var memoryBytes: UInt64 { members.compactMap(\.memoryBytes).reduce(0, +) }
    /// „Codex-Broker (Claude-Code-Plugin), PID 89059 (4 Prozesse)“ – ohne Befehlszeile.
    public var title: String {
        "\(pattern.displayName), PID \(root.pid) (\(processCount == 1 ? "1 Prozess" : "\(processCount) Prozesse"))"
    }
    public var startDate: Date { Date(timeIntervalSince1970: TimeInterval(root.startTime) / 1_000_000) }
}

/// Ergebnis der Suche.
public struct AgentTreeScan: Hashable, Sendable {
    /// Größter Speicher zuerst.
    public let orphans: [AgentProcessTree]
    /// Bäume mit ppid 1, die zu einer laufenden Sitzung gehören und deshalb nicht angeboten werden.
    public let inUseCount: Int

    public init(orphans: [AgentProcessTree], inUseCount: Int) {
        self.orphans = orphans
        self.inUseCount = inUseCount
    }
}

/// Findet verwaiste Agenten-Bäume in der Prozesstabelle (#221). Eine Wurzel muss
/// - dem eigenen Benutzer gehören, ppid 1 haben und zu einem Muster aus `AgentProcessCatalog.orphanRoots` passen;
/// - bei nicht geteilten Mustern **kein** Sitzungsleiter sein: launchd startet Dienste mit eigener Sitzung, das Kind
///   einer beendeten Agenten-Sitzung behält dagegen deren Sitzung (unlesbar zählt wie Sitzungsleiter, fail-closed).
///
/// Nie angeboten wird ein Baum, der Grantry selbst oder den Helper enthält (eigene PID, eigenes Bundle, jedes
/// `Grantry.app` und `GrantryHelper`), eine laufende Sitzung enthält oder – bei geteilten Mustern wie dem Codex-Broker –
/// dessen Arbeitsordner sich mit dem einer laufenden Sitzung überschneidet (ohne lesbaren Arbeitsordner des Brokers
/// oder bei nicht vollständig feststellbaren Sitzungen: in Benutzung).
/// Unterbäume fremder Benutzer bleiben außen vor; sie ließen sich ohne Helper nicht beenden.
public struct OrphanAgentTreeDetector: Sendable {
    private let catalog: AgentProcessCatalog
    private let currentUID: UInt32
    private let ownPID: pid_t
    private let protectedBundlePaths: [String]

    public init(catalog: AgentProcessCatalog = .standard, currentUID: UInt32 = getuid(), ownPID: pid_t = getpid(),
                protectedBundlePaths: [String] = [Bundle.main.bundlePath]) {
        self.catalog = catalog
        self.currentUID = currentUID
        self.ownPID = ownPID
        self.protectedBundlePaths = protectedBundlePaths
    }

    public func scan(_ entries: [ProcessEntry]) -> AgentTreeScan {
        let own = entries.filter { $0.uid == currentUID }
        let children = Dictionary(grouping: own, by: \.parentPID)
        let sessionWorkspaces = sessionWorkspaces(of: own)
        var orphans: [AgentProcessTree] = []
        var inUse = 0
        for root in own where root.parentPID == 1 && root.pid != ownPID {
            guard let pattern = catalog.orphanPattern(for: root),
                  pattern.isSharedAcrossSessions || root.isSessionLeader == false else { continue }
            let members = Self.subtree(of: root, children: children)
            guard !members.contains(where: isGrantry) else { continue }
            let workspace = pattern.workspace(of: root)
            let sharedInUse = pattern.isSharedAcrossSessions && {
                guard let workspace, let sessionWorkspaces else { return true }
                return Self.overlaps(FilePath.canonical(workspace), sessionWorkspaces)
            }()
            if sharedInUse || members.contains(where: catalog.isSession) {
                inUse += 1
                continue
            }
            orphans.append(AgentProcessTree(pattern: pattern, members: members, workspace: workspace))
        }
        return AgentTreeScan(orphans: orphans.sorted { $0.memoryBytes > $1.memoryBytes }, inUseCount: inUse)
    }

    /// Kanonische Arbeitsordner aller laufenden Sitzungen; `nil`, wenn die Zuordnung nicht vollständig feststellbar ist:
    /// eine Sitzung ohne lesbaren Arbeitsordner oder ein eigener Prozess ohne lesbare Argumente (ob er eine Sitzung
    /// ist, bleibt offen). Geteilte Prozesse gelten dann als in Benutzung (fail-closed, Codex-Review #221).
    private func sessionWorkspaces(of own: [ProcessEntry]) -> [String]? {
        var workspaces: [String] = []
        for entry in own where entry.pid != ownPID {
            guard !entry.arguments.isEmpty else { return nil }
            guard catalog.isSession(entry) else { continue }
            guard let directory = entry.workingDirectory else { return nil }
            workspaces.append(FilePath.canonical(directory))
        }
        return workspaces
    }

    /// Breitensuche ab `root`; jede PID einmal.
    static func subtree(of root: ProcessEntry, children: [pid_t: [ProcessEntry]]) -> [ProcessEntry] {
        var result = [root]
        var seen: Set<pid_t> = [root.pid]
        var index = 0
        while index < result.count {
            for child in children[result[index].pid] ?? [] where seen.insert(child.pid).inserted {
                result.append(child)
            }
            index += 1
        }
        return result
    }

    /// Gleich, darüber oder darunter.
    private static func overlaps(_ workspace: String, _ sessions: [String]) -> Bool {
        sessions.contains { session in
            session == workspace || workspace.hasPrefix(session + "/") || session.hasPrefix(workspace + "/")
        }
    }

    /// Grantry selbst, der Helper oder ein anderes Grantry (etwa ein Entwicklungs-Build) – nie anbieten. Geprüft werden
    /// Programmpfad **und** argv[0], weil der Pfad nach einem Update der App unlesbar sein kann.
    private func isGrantry(_ entry: ProcessEntry) -> Bool {
        guard entry.pid != ownPID else { return true }
        return ([entry.executablePath] + entry.arguments.prefix(1)).contains { path in
            if protectedBundlePaths.contains(where: { ProcessTerminationPolicy.isInBundle(path, bundlePath: $0) }) {
                return true
            }
            if ProcessEntry.lastComponent(path) == "GrantryHelper" { return true }
            return ProcessTerminationPolicy.enclosingAppBundle(ofExecutable: path)
                .map { ProcessEntry.lastComponent($0) == "Grantry.app" } ?? false
        }
    }
}
