import Foundation
import Testing
@testable import ManagerKit

/// Prozessbäume aus Fakes; `entry` setzt nur, was die Regeln lesen.
enum ProcessFixture {
    static let uid: UInt32 = 501
    static let ownPID: pid_t = 900
    static let grantryBundle = "/Applications/Grantry.app"
    static let broker = "/Users/me/.claude/plugins/cache/openai-codex/codex/1.0.2/scripts/app-server-broker.mjs"

    static func entry(_ pid: pid_t, parent: pid_t, _ arguments: [String], executable: String? = nil,
                      uid: UInt32 = uid, cwd: String? = nil, memory: UInt64? = 100, leader: Bool? = false,
                      start: UInt64? = nil) -> ProcessEntry {
        ProcessEntry(pid: pid, parentPID: parent, uid: uid, startTime: start ?? UInt64(pid) * 1_000,
                     executablePath: executable ?? arguments.first ?? "", arguments: arguments, workingDirectory: cwd,
                     memoryBytes: memory, isSessionLeader: leader)
    }

    /// Codex-Broker (ppid 1, eigene Sitzung wie bei `detached: true`) mit App-Server und zwei MCP-Servern.
    static func brokerTree(workspace: String = "/Users/me/project", rootPID: pid_t = 100) -> [ProcessEntry] {
        [
            entry(rootPID, parent: 1, ["/opt/homebrew/bin/node", broker, "serve", "--cwd", workspace], leader: true),
            entry(rootPID + 1, parent: rootPID, ["node", "/opt/homebrew/bin/codex", "app-server"],
                  executable: "/opt/homebrew/Cellar/node/26/bin/node"),
            entry(rootPID + 2, parent: rootPID + 1, ["/opt/homebrew/lib/codex", "app-server"]),
            entry(rootPID + 3, parent: rootPID + 2, ["/Users/me/.bun/bin/bun", "/Users/me/peers/server.ts"]),
            entry(rootPID + 4, parent: rootPID + 2, ["npm exec chrome-devtools-mcp@latest"],
                  executable: "/opt/homebrew/bin/node"),
        ]
    }

    static func claudeSession(_ pid: pid_t, cwd: String) -> ProcessEntry {
        entry(pid, parent: 50, ["claude", "--permission-mode", "auto"], executable: "/opt/homebrew/bin/claude", cwd: cwd)
    }

    static let detector = OrphanAgentTreeDetector(currentUID: uid, ownPID: ownPID, protectedBundlePaths: [grantryBundle])
}

@Suite struct OrphanAgentTreeDetectorTests {
    private typealias F = ProcessFixture

    @Test func orphanedBrokerIsOfferedWithWholeSubtreeRootFirst() throws {
        let scan = F.detector.scan(F.brokerTree())
        let tree = try #require(scan.orphans.first)
        #expect(scan.orphans.count == 1)
        #expect(tree.pattern.id == "codexBroker")
        #expect(tree.members.map(\.pid) == [100, 101, 102, 103, 104])
        #expect(tree.memoryBytes == 500)
        #expect(tree.workspace == "/Users/me/project")
        #expect(scan.inUseCount == 0)
    }

    @Test(arguments: ["/Users/me/project", "/Users/me", "/Users/me/project/sub"])
    func brokerSharedWithRunningSessionIsNotOffered(_ sessionCWD: String) {
        let scan = F.detector.scan(F.brokerTree() + [F.claudeSession(300, cwd: sessionCWD)])
        #expect(scan.orphans.isEmpty)
        #expect(scan.inUseCount == 1)
    }

    @Test func brokerOfOtherWorkspaceStaysOffered() {
        let scan = F.detector.scan(F.brokerTree() + [F.claudeSession(300, cwd: "/Users/me/project-two")])
        #expect(scan.orphans.count == 1)
    }

    @Test func brokerWithoutReadableWorkspaceCountsAsInUse() {
        var entries = F.brokerTree()
        entries[0] = F.entry(100, parent: 1, ["/opt/homebrew/bin/node", F.broker, "serve"], leader: true)
        let scan = F.detector.scan(entries)
        #expect(scan.orphans.isEmpty)
        #expect(scan.inUseCount == 1)
    }

    /// Codex-Review #221: Eine Sitzung ohne lesbaren Arbeitsordner darf den Broker nicht freigeben.
    @Test func sessionWithUnreadableWorkspaceKeepsBrokerInUse() {
        let session = F.entry(300, parent: 50, ["claude"], executable: "/opt/homebrew/bin/claude", cwd: nil)
        let scan = F.detector.scan(F.brokerTree() + [session])
        #expect(scan.orphans.isEmpty)
        #expect(scan.inUseCount == 1)
    }

    /// Ein eigener Prozess ohne lesbare Argumente könnte eine Sitzung sein: geteilte Broker bleiben unangetastet,
    /// nicht geteilte Waisen (MCP-Server mit ppid 1) werden weiter angeboten.
    @Test func unreadableProcessKeepsOnlySharedBrokersInUse() {
        let unknown = F.entry(300, parent: 50, [], executable: "")
        let mcp = F.entry(400, parent: 1, ["/opt/homebrew/bin/node", "/x/foo-mcp"])
        let scan = F.detector.scan(F.brokerTree() + [unknown, mcp])
        #expect(scan.orphans.map(\.root.pid) == [400])
        #expect(scan.inUseCount == 1)
    }

    /// Alte Waisen laufen oft mit gelöschter Programmdatei (`brew upgrade node`); erkannt werden sie über argv.
    @Test func orphanWithDeletedExecutableIsOffered() throws {
        let entries = [F.entry(301, parent: 1, ["/opt/homebrew/Cellar/node/26.11.1/bin/node", "/x/foo-mcp"], executable: "")]
        let tree = try #require(F.detector.scan(entries).orphans.first)
        #expect(tree.root.runningProcess.executablePath == "")
        #expect(tree.root.label == "node foo-mcp")
    }

    @Test func grantryWithUnreadableExecutableIsRecognizedByArgv0() {
        let entries = F.brokerTree(workspace: "/w")
            + [F.entry(105, parent: 104, ["/Applications/Grantry.app/Contents/MacOS/Grantry"], executable: "")]
        #expect(F.detector.scan(entries).orphans.isEmpty)
    }

    @Test func treeContainingSessionIsNotOffered() {
        let entries = F.brokerTree() + [F.claudeSession(105, cwd: "/elsewhere").reparented(to: 104)]
        #expect(F.detector.scan(entries).orphans.isEmpty)
    }

    @Test func processWithLivingParentIsNotOrphaned() {
        let entries = [
            F.claudeSession(300, cwd: "/a"),
            F.entry(301, parent: 300, ["/opt/homebrew/bin/node", "/x/node_modules/.bin/mcp-server-postgres", "postgres://u:geheim@h/db"]),
        ]
        #expect(F.detector.scan(entries).orphans.isEmpty)
    }

    @Test func orphanedMCPServerIsOffered() throws {
        let entries = [F.entry(301, parent: 1, ["/opt/homebrew/bin/node", "/x/node_modules/.bin/mcp-server-postgres",
                                                "postgres://u:geheim@h/db"])]
        let tree = try #require(F.detector.scan(entries).orphans.first)
        #expect(tree.pattern.id == "mcpServer")
        // Angezeigt wird nur Programm- und Skriptname, nie die Befehlszeile mit Geheimnissen.
        #expect(tree.root.label == "node mcp-server-postgres")
        #expect(!tree.root.label.contains("geheim"))
    }

    /// launchd startet Dienste mit eigener Sitzung: Ein als LaunchAgent laufender MCP-Server ist nicht verwaist.
    @Test(arguments: [true, nil] as [Bool?])
    func sessionLeaderOrUnknownSessionIsNotOffered(_ leader: Bool?) {
        let entries = [F.entry(301, parent: 1, ["/opt/homebrew/bin/node", "/x/bin/some-mcp"], leader: leader)]
        #expect(F.detector.scan(entries).orphans.isEmpty)
    }

    @Test func unrelatedOrphanIsIgnored() {
        let entries = [F.entry(301, parent: 1, ["/Users/me/.bun/bin/bun", "/Users/me/claude-peers-mcp-gateway/agent/agent.ts"])]
        #expect(F.detector.scan(entries).orphans.isEmpty)
    }

    @Test func foreignUserIsNeitherRootNorMember() throws {
        var entries = F.brokerTree()
        entries[4] = F.entry(104, parent: 102, ["/usr/bin/sudo"], uid: 0)
        entries.append(F.entry(105, parent: 104, ["/opt/homebrew/bin/node", "/x/foo-mcp"]))
        entries.append(F.entry(400, parent: 1, ["/opt/homebrew/bin/node", "/x/foo-mcp"], uid: 502))
        let scan = F.detector.scan(entries)
        #expect(scan.orphans.map(\.root.pid) == [100])
        #expect(try #require(scan.orphans.first).members.map(\.pid) == [100, 101, 102, 103])
    }

    // MARK: - Grantry und Helper

    @Test(arguments: [
        "/Applications/Grantry.app/Contents/MacOS/Grantry",
        "/Applications/Grantry.app/Contents/Library/LaunchServices/de.cstrube.Grantry.Helper",
        "/Users/me/DerivedData/Build/Products/Debug/Grantry.app/Contents/MacOS/Grantry",
        "/somewhere/GrantryHelper",
    ])
    func treeContainingGrantryIsNeverOffered(_ grantry: String) {
        let entries = F.brokerTree(workspace: "/w") + [F.entry(105, parent: 104, [grantry])]
        #expect(F.detector.scan(entries).orphans.isEmpty)
    }

    @Test func ownProcessIsNeverRoot() {
        let entries = [F.entry(F.ownPID, parent: 1, ["/opt/homebrew/bin/node", "/x/foo-mcp"])]
        #expect(F.detector.scan(entries).orphans.isEmpty)
    }

    @Test func treeContainingOwnPIDIsNeverOffered() {
        let entries = F.brokerTree(workspace: "/w") + [F.entry(F.ownPID, parent: 104, ["/opt/x/whatever"])]
        #expect(F.detector.scan(entries).orphans.isEmpty)
    }

    @Test func largestTreeComesFirst() {
        let small = F.entry(301, parent: 1, ["/opt/homebrew/bin/node", "/x/a-mcp"], memory: 10)
        let large = F.entry(302, parent: 1, ["/opt/homebrew/bin/node", "/x/b-mcp"], memory: 1_000)
        #expect(F.detector.scan([small, large]).orphans.map(\.root.pid) == [302, 301])
    }
}

@Suite struct AgentProcessCatalogTests {
    private typealias F = ProcessFixture

    @Test(arguments: [
        ("chrome-devtools-mcp@latest", "chrome-devtools-mcp"),
        ("/x/node_modules/@scope/pkg@1.2.3", "pkg"),
        ("@modelcontextprotocol/server-github", "server-github"),
        ("mcp-server-postgres", "mcp-server-postgres"),
    ])
    func packageNames(_ argument: String, _ expected: String) {
        #expect(AgentProcessPattern.packageName(argument) == expected)
    }

    @Test func codexAppServerIsNoSession() {
        let catalog = AgentProcessCatalog.standard
        #expect(!catalog.isSession(F.entry(1, parent: 2, ["/opt/homebrew/bin/codex", "app-server"])))
        #expect(catalog.isSession(F.entry(1, parent: 2, ["/opt/homebrew/bin/codex"])))
        #expect(catalog.isSession(F.entry(1, parent: 2, ["node", "/opt/homebrew/bin/codex", "--full-auto"],
                                          executable: "/opt/homebrew/bin/node")))
        #expect(catalog.isSession(F.entry(1, parent: 2, ["claude"], executable: "/Users/me/.local/bin/claude")))
    }

    @Test func brokerMatchesBeforeGenericPluginServer() {
        let root = F.brokerTree()[0]
        #expect(AgentProcessCatalog.standard.orphanPattern(for: root)?.id == "codexBroker")
    }

    @Test func procArgumentsAreParsed() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes += $0 }
        bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0, 0]
        for argument in ["node", "/x/server.js", "--port=1"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("PATH=/usr/bin".utf8) + [0]
        #expect(LibprocProcessTable.parseArguments(bytes) == ["node", "/x/server.js", "--port=1"])
        #expect(LibprocProcessTable.parseArguments([1, 0]) == [])
    }
}

extension ProcessEntry {
    func reparented(to parent: pid_t) -> ProcessEntry {
        ProcessEntry(pid: pid, parentPID: parent, uid: uid, startTime: startTime, executablePath: executablePath,
                     arguments: arguments, workingDirectory: workingDirectory, memoryBytes: memoryBytes,
                     isSessionLeader: isSessionLeader)
    }
}
