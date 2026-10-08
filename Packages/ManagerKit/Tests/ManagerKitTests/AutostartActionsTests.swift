import Testing
import Foundation
import Synchronization
import TestSupport
@testable import ManagerKit

/// Protokolliert privilegierte Aufrufe; wirft optional `failure` bei jedem Aufruf.
private final class RecordingPrivileged: PrivilegedAutostartControlling {
    private let calls = Mutex<[String]>([])
    private let failure: (any Error & Sendable)?
    private let restoredPath: String
    /// Ob `unloadAndRemovePlist` meldet, den Dienst entladen zu haben (wie der Helper für einen geladenen Daemon).
    private let unloads: Bool
    /// Protokollversion des Helpers (oder ihr Fehler, etwa „nicht erreichbar“); unabhängig von `failure`.
    private let version: Result<Int, HelperClientError>

    init(
        failure: (any Error & Sendable)? = nil, restoredPath: String = "/Library/LaunchDaemons/x.plist", unloads: Bool = false,
        version: Result<Int, HelperClientError> = .success(HelperXPC.protocolVersion)
    ) {
        self.failure = failure
        self.restoredPath = restoredPath
        self.unloads = unloads
        self.version = version
    }

    var recorded: [String] { calls.withLock { $0 } }
    /// Mit `unloadAndRemovePlist` übergebene Fingerabdrücke aus dem Scan, in Aufrufreihenfolge.
    let expectedFingerprints = Mutex<[FileFingerprint?]>([])

    private func record(_ call: String) throws {
        calls.withLock { $0.append(call) }
        if let failure { throw failure }
    }

    func protocolVersion() async throws -> Int { try version.get() }
    func setEnabled(plistPath: String, enabled: Bool) async throws { try record("\(enabled ? "enable" : "disable") \(plistPath)") }
    func bootout(plistPath: String) async throws { try record("bootout \(plistPath)") }
    func bootstrap(plistPath: String) async throws { try record("bootstrap \(plistPath)") }
    func unloadAndRemovePlist(path: String, expectedFingerprint: FileFingerprint?) async throws -> PrivilegedPlistRemoval {
        expectedFingerprints.withLock { $0.append(expectedFingerprint) }
        try record("remove \(path)")
        return PrivilegedPlistRemoval(backupPath: "/backup\(path)", wasUnloaded: unloads)
    }
    func restorePlist(backupPath: String) async throws -> String { try record("restore \(backupPath)"); return restoredPath }
}

@Suite struct AutostartActionsTests {
    private static let ok = CommandResult(exitCode: 0, stdout: "")
    /// `launchctl print gui/<uid>/<label>`, wenn kein Dienst mit dem Label geladen ist.
    private static let notLoaded = CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service")

    /// `launchctl print gui/<uid>/<label>` eines aus `plist` geladenen Dienstes.
    private static func loaded(from plist: String) -> CommandResult {
        CommandResult(exitCode: 0, stdout: "gui/501/x = {\n\tactive count = 1\n\tpath = \(plist)\n\ttype = LaunchAgent\n}\n")
    }

    /// Befehlszeile der Ladezustandsprüfung für `label` in `gui/501`.
    private static func probe(_ label: String) -> String { "/bin/launchctl print gui/501/\(label)" }

    /// Befehlszeile der Ladezustandsprüfung für den LaunchDaemon `label` in `system`.
    private static func systemProbe(_ label: String) -> String { "/bin/launchctl print system/\(label)" }

    private func item(_ label: String, kind: AutostartKind, domain: AutostartDomain, plist: String, loaded: Bool?,
                      enabled: Bool = true) -> AutostartItem {
        AutostartItem(kind: kind, domain: domain, label: label, program: "/usr/local/bin/\(label)", programPresence: .present,
                      isEnabled: enabled, isLoaded: loaded, plistPath: plist, owner: nil, source: .launchd)
    }

    /// Die Prüfung auf doppelte Labels (#138) liest nur die Verzeichnisse unter `home`, nie `/Library/LaunchAgents`.
    private func actions(_ runner: any CommandRunning = MockCommandRunner(), _ privileged: RecordingPrivileged = RecordingPrivileged(),
                         home: String = "/Users/x", launchAgentDirectories: [String]? = nil) -> AutostartActions {
        AutostartActions(
            runner: runner, privileged: privileged, userBackups: .user(home: home), uid: 501,
            launchAgentDirectories: launchAgentDirectories ?? [home + "/Library/LaunchAgents"]
        )
    }

    // MARK: - Aktivieren/Deaktivieren

    @Test func disablingUserAgentRunsLaunchctlDirectlyAndBootsOutByPathIfLoaded() async throws {
        let plist = "/Users/x/Library/LaunchAgents/com.example.agent.plist"
        let runner = MockCommandRunner([
            Self.probe("com.example.agent"): Self.loaded(from: plist),
            "/bin/launchctl disable gui/501/com.example.agent": Self.ok,
            "/bin/launchctl bootout gui/501 \(plist)": Self.ok,
        ])
        let privileged = RecordingPrivileged()
        try await actions(runner, privileged).setEnabled(
            item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist, loaded: true), false)
        #expect(runner.calls == [
            Self.probe("com.example.agent"), "/bin/launchctl disable gui/501/com.example.agent", "/bin/launchctl bootout gui/501 \(plist)",
        ])
        #expect(privileged.recorded.isEmpty)
    }

    @Test func enablingSystemAgentRunsLaunchctlInGuiDomainAndBootstrapsIfNotLoaded() async throws {
        let plist = "/Library/LaunchAgents/com.vendor.agent.plist"
        let runner = MockCommandRunner([
            Self.probe("com.vendor.agent"): Self.notLoaded,
            "/bin/launchctl enable gui/501/com.vendor.agent": Self.ok,
            "/bin/launchctl bootstrap gui/501 \(plist)": Self.ok,
        ])
        let privileged = RecordingPrivileged()
        try await actions(runner, privileged).setEnabled(item("com.vendor.agent", kind: .launchAgent, domain: .system, plist: plist, loaded: false), true)
        #expect(runner.calls == [
            Self.probe("com.vendor.agent"), "/bin/launchctl enable gui/501/com.vendor.agent", "/bin/launchctl bootstrap gui/501 \(plist)",
        ])
        #expect(privileged.recorded.isEmpty)
    }

    /// Auch für LaunchDaemons fragt die App den Ladezustand bei launchd ab (`print system/<label>`, lesend); die
    /// Änderung selbst läuft über den Helper, der die Zuordnung seinerseits prüft.
    @Test func enablingDaemonGoesThroughHelperAndBootstrapsIfNotLoaded() async throws {
        let runner = MockCommandRunner([Self.systemProbe("com.docker.helper"): Self.notLoaded])
        let privileged = RecordingPrivileged()
        let plist = "/Library/LaunchDaemons/com.docker.helper.plist"
        try await actions(runner, privileged).setEnabled(item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: plist, loaded: false), true)
        #expect(privileged.recorded == ["enable \(plist)", "bootstrap \(plist)"])
        #expect(runner.calls == [Self.systemProbe("com.docker.helper")])
    }

    @Test func disablingLoadedDaemonGoesThroughHelperAndBootsOut() async throws {
        let privileged = RecordingPrivileged()
        let plist = "/Library/LaunchDaemons/com.docker.helper.plist"
        let runner = MockCommandRunner([Self.systemProbe("com.docker.helper"): Self.loaded(from: plist)])
        try await actions(runner, privileged).setEnabled(item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: plist, loaded: true), false)
        #expect(privileged.recorded == ["disable \(plist)", "bootout \(plist)"])
        #expect(runner.calls == [Self.systemProbe("com.docker.helper")])
    }

    /// Der Scan ist kein Beleg: Was launchd gerade meldet, entscheidet über `bootout`/`bootstrap` – auch bei Daemons.
    @Test func daemonLoadStateComesFromLaunchdNotFromScan() async throws {
        let plist = "/Library/LaunchDaemons/com.docker.helper.plist"
        let staleUnloaded = RecordingPrivileged()
        try await actions(MockCommandRunner([Self.systemProbe("com.docker.helper"): Self.loaded(from: plist)]), staleUnloaded)
            .setEnabled(item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: plist, loaded: false), false)
        #expect(staleUnloaded.recorded == ["disable \(plist)", "bootout \(plist)"])

        let staleLoaded = RecordingPrivileged()
        try await actions(MockCommandRunner([Self.systemProbe("com.docker.helper"): Self.notLoaded]), staleLoaded)
            .setEnabled(item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: plist, loaded: true), false)
        #expect(staleLoaded.recorded == ["disable \(plist)"])
    }

    /// Unter dem Label des Daemons ist ein Dienst aus einer anderen Plist geladen (#99): Die App bricht ab, bevor sie
    /// den Helper überhaupt bemüht – der lehnte ebenso ab.
    @Test func daemonWithLabelLoadedFromAnotherPlistIsRefusedBeforeTheHelper() async {
        let plist = "/Library/LaunchDaemons/org.cups.cupsd.plist"
        let runner = MockCommandRunner([Self.systemProbe("org.cups.cupsd"): Self.loaded(from: "/System/Library/LaunchDaemons/org.cups.cupsd.plist")])
        let privileged = RecordingPrivileged()
        for enabled in [false, true] {
            await #expect(throws: ActionError.notAllowed(.conflictingService)) {
                try await actions(runner, privileged).setEnabled(item("org.cups.cupsd", kind: .launchDaemon, domain: .system, plist: plist, loaded: false), enabled)
            }
        }
        #expect(privileged.recorded.isEmpty)
        #expect(runner.calls == [Self.systemProbe("org.cups.cupsd"), Self.systemProbe("org.cups.cupsd")])
    }

    /// Entfernen bei Kollision: nur die Datei über den Helper sichern und löschen, kein `bootout`.
    @Test func removingCollidingDaemonSkipsBootout() async throws {
        let plist = "/Library/LaunchDaemons/org.cups.cupsd.plist"
        let runner = MockCommandRunner([Self.systemProbe("org.cups.cupsd"): Self.loaded(from: "/System/Library/LaunchDaemons/org.cups.cupsd.plist")])
        let privileged = RecordingPrivileged()
        let receipt = try await actions(runner, privileged).remove(item("org.cups.cupsd", kind: .launchDaemon, domain: .system, plist: plist, loaded: true))
        #expect(privileged.recorded == ["remove \(plist)"])
        #expect(!receipt.wasLoaded)
    }

    /// Lässt sich der Ladezustand eines Daemons nicht feststellen, wird der Helper nicht aufgerufen. (Entfernen fragt
    /// launchd im Helper selbst, #166.)
    @Test func failedDaemonProbeStopsBeforeTheHelper() async {
        let plist = "/Library/LaunchDaemons/com.docker.helper.plist"
        let runner = MockCommandRunner([Self.systemProbe("com.docker.helper"): CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error")])
        let privileged = RecordingPrivileged()
        await #expect(throws: ActionError.commandFailed("launchctl print system/com.docker.helper fehlgeschlagen (Exit 5): Input/output error")) {
            try await actions(runner, privileged).setEnabled(item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: plist, loaded: true), false)
        }
        #expect(privileged.recorded.isEmpty)
    }

    @Test func alreadyMatchingLoadStateSkipsBootoutAndBootstrap() async throws {
        let plist = "/Users/x/Library/LaunchAgents/com.example.agent.plist"
        let runner = MockCommandRunner([
            Self.probe("com.example.agent"): Self.notLoaded,
            "/bin/launchctl disable gui/501/com.example.agent": Self.ok,
        ])
        try await actions(runner).setEnabled(item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist, loaded: false), false)
        #expect(runner.calls == [Self.probe("com.example.agent"), "/bin/launchctl disable gui/501/com.example.agent"])

        let enabling = MockCommandRunner([
            Self.probe("com.example.agent"): Self.loaded(from: plist),
            "/bin/launchctl enable gui/501/com.example.agent": Self.ok,
        ])
        try await actions(enabling).setEnabled(item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist, loaded: true), true)
        #expect(enabling.calls == [Self.probe("com.example.agent"), "/bin/launchctl enable gui/501/com.example.agent"])
    }

    /// Der Ladezustand kommt frisch von launchd, nicht aus dem (womöglich veralteten) Scan.
    @Test func loadStateComesFromLaunchdNotFromScan() async throws {
        let plist = "/Users/x/Library/LaunchAgents/com.example.agent.plist"
        let runner = MockCommandRunner([
            Self.probe("com.example.agent"): Self.loaded(from: plist),
            "/bin/launchctl disable gui/501/com.example.agent": Self.ok,
            "/bin/launchctl bootout gui/501 \(plist)": Self.ok,
        ])
        try await actions(runner).setEnabled(item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist, loaded: false), false)
        #expect(runner.calls.last == "/bin/launchctl bootout gui/501 \(plist)")
    }

    // MARK: - Label-Kollision

    /// Getarnter Agent mit dem Label eines echten Apple-Dienstes: Geladen ist der Apple-Dienst (andere Plist). Weder
    /// Override noch `bootout` dürfen per Label laufen – sie träfen den echten Dienst.
    @Test func collidingLabelIsNeitherOverriddenNorBootedOut() async {
        var disguised = TestData.disguisedAppleAgent
        disguised.label = "com.apple.Dock.agent"
        let runner = MockCommandRunner([Self.probe("com.apple.Dock.agent"): Self.loaded(from: "/System/Library/LaunchAgents/com.apple.Dock.plist")])
        for enabled in [false, true] {
            await #expect(throws: ActionError.notAllowed(.conflictingService)) {
                try await actions(runner).setEnabled(disguised, enabled)
            }
        }
        #expect(runner.calls == [Self.probe("com.apple.Dock.agent"), Self.probe("com.apple.Dock.agent")])
    }

    /// Entfernen bei Kollision: Datei sichern und löschen, aber kein `bootout` und kein Label-Override.
    @Test func removingCollidingAgentOnlyDeletesItsPlist() async throws {
        try await ScratchDirectory.with { home in
            let label = "com.apple.Dock.agent"
            let plist = try LaunchdPlistFixture.write(label: label, in: home.appending(path: "Library/LaunchAgents"))
            let runner = MockCommandRunner([Self.probe(label): Self.loaded(from: "/System/Library/LaunchAgents/com.apple.Dock.plist")])
            var disguised = item(label, kind: .launchAgent, domain: .user, plist: plist.path, loaded: true)
            disguised.program = home.appending(path: "Library/.x/agent").path
            disguised.programSigning = SigningInfo(kind: .unsigned)

            let receipt = try await actions(runner, home: home.path).remove(disguised)
            #expect(runner.calls == [Self.probe(label)])
            #expect(!FileManager.default.fileExists(atPath: plist.path))
            #expect(FileManager.default.fileExists(atPath: receipt.backupPath))
            #expect(!receipt.wasLoaded)
        }
    }

    /// Ein aus einer anderen Plist geladener Dienst mit gleichem Label wird auch bei Systemagenten nicht entladen.
    @Test func removingCollidingSystemAgentSkipsBootout() async throws {
        let plist = "/Library/LaunchAgents/com.vendor.agent.plist"
        let runner = MockCommandRunner([Self.probe("com.vendor.agent"): Self.loaded(from: "/Users/x/Library/LaunchAgents/com.vendor.agent.plist")])
        let privileged = RecordingPrivileged()
        let receipt = try await actions(runner, privileged).remove(item("com.vendor.agent", kind: .launchAgent, domain: .system, plist: plist, loaded: true))
        #expect(runner.calls == [Self.probe("com.vendor.agent")])
        #expect(privileged.recorded == ["remove \(plist)"])
        #expect(!receipt.wasLoaded)
    }

    /// Ein geladener Dienst ohne erkennbaren Plist-Pfad (etwa per XPC eingereicht) gilt ebenfalls als fremd.
    @Test func loadedServiceWithoutPathCountsAsConflict() async {
        let runner = MockCommandRunner([Self.probe("com.example.agent"): CommandResult(exitCode: 0, stdout: "gui/501/com.example.agent = {\n\ttype = LaunchAgent\n}\n")])
        await #expect(throws: ActionError.notAllowed(.conflictingService)) {
            try await actions(runner).setEnabled(
                item("com.example.agent", kind: .launchAgent, domain: .user, plist: "/Users/x/Library/LaunchAgents/com.example.agent.plist", loaded: true), false)
        }
        #expect(runner.calls == [Self.probe("com.example.agent")])
    }

    /// Der eigene, geladene Tarn-Agent lässt sich per Label deaktivieren und per Pfad entladen.
    @Test func ownLoadedDisguisedAgentIsDisabled() async throws {
        let disguised = TestData.disguisedAppleAgent
        let plist = try #require(disguised.plistPath)
        let runner = MockCommandRunner([
            Self.probe(disguised.label): Self.loaded(from: plist),
            "/bin/launchctl disable gui/501/\(disguised.label)": Self.ok,
            "/bin/launchctl bootout gui/501 \(plist)": Self.ok,
        ])
        try await actions(runner).setEnabled(disguised, false)
        #expect(runner.calls == [
            Self.probe(disguised.label), "/bin/launchctl disable gui/501/\(disguised.label)", "/bin/launchctl bootout gui/501 \(plist)",
        ])
    }

    /// Lässt sich der Ladezustand nicht feststellen, läuft kein verändernder Befehl.
    @Test func failedProbeStopsBeforeAnyChange() async {
        let runner = MockCommandRunner([Self.probe("com.example.agent"): CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error")])
        await #expect(throws: ActionError.commandFailed("launchctl print gui/501/com.example.agent fehlgeschlagen (Exit 5): Input/output error")) {
            try await actions(runner).setEnabled(
                item("com.example.agent", kind: .launchAgent, domain: .user, plist: "/Users/x/Library/LaunchAgents/com.example.agent.plist", loaded: true), false)
        }
        #expect(runner.calls == [Self.probe("com.example.agent")])
    }

    // MARK: - Entfernen/Wiederherstellen

    /// Vor dem `bootout` liest die App die Plist (gebundene Bytes für einen etwaigen Rollback, #166) – daher eine echte
    /// Datei im Scratch-Verzeichnis statt eines Systempfads.
    @Test func removingSystemAgentBootsOutInGuiDomainAndDeletesViaHelper() async throws {
        try await ScratchDirectory.with { directory in
            let plist = try LaunchdPlistFixture.write(label: "com.vendor.agent", in: directory).path
            let runner = MockCommandRunner([Self.probe("com.vendor.agent"): Self.loaded(from: plist), "/bin/launchctl bootout gui/501 \(plist)": Self.ok])
            let privileged = RecordingPrivileged()
            let receipt = try await actions(runner, privileged).remove(item("com.vendor.agent", kind: .launchAgent, domain: .system, plist: plist, loaded: true))
            #expect(runner.calls == [Self.probe("com.vendor.agent"), "/bin/launchctl bootout gui/501 \(plist)"])
            #expect(privileged.recorded == ["remove \(plist)"])
            #expect(receipt == RemovalReceipt(label: "com.vendor.agent", backupPath: "/backup\(plist)",
                                              isPrivileged: true, wasEnabled: true, wasLoaded: true))
        }
    }

    @Test func restoringSystemAgentRestoresViaHelperAndBootstrapsInGuiDomain() async throws {
        let restored = "/Library/LaunchAgents/com.vendor.agent.plist"
        let runner = MockCommandRunner(["/bin/launchctl bootstrap gui/501 \(restored)": Self.ok])
        let privileged = RecordingPrivileged(restoredPath: restored)
        let receipt = RemovalReceipt(label: "com.vendor.agent", backupPath: "/b/x.plist", isPrivileged: true, wasEnabled: true, wasLoaded: true)
        try await actions(runner, privileged).restore(receipt)
        #expect(privileged.recorded == ["restore /b/x.plist"])
        #expect(runner.calls == ["/bin/launchctl bootstrap gui/501 \(restored)"])
    }

    @Test func restoredDaemonBootstrapsInSystemDomainRegardlessOfReceipt() async throws {
        // Ein manipulierter Beleg kann die Domain nicht mehr vorgeben: Sie folgt aus dem wiederhergestellten Pfad.
        let restored = "/Library/LaunchDaemons/com.docker.helper.plist"
        let runner = MockCommandRunner()
        let privileged = RecordingPrivileged(restoredPath: restored)
        let receipt = RemovalReceipt(label: "com.vendor.agent", backupPath: "/b/x.plist", isPrivileged: true, wasEnabled: true, wasLoaded: true)
        try await actions(runner, privileged).restore(receipt)
        #expect(privileged.recorded == ["restore /b/x.plist", "bootstrap \(restored)"])
        #expect(runner.calls.isEmpty)
    }

    @Test func restoringDisabledOrUnloadedEntryDoesNotBootstrap() async throws {
        let plist = "/Library/LaunchDaemons/com.docker.helper.plist"
        for (enabled, loaded) in [(false, false), (true, false)] {
            let runner = MockCommandRunner([Self.systemProbe("com.docker.helper"): Self.notLoaded])
            let privileged = RecordingPrivileged(restoredPath: plist)
            let actions = actions(runner, privileged)
            let receipt = try await actions.remove(
                item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: plist, loaded: loaded, enabled: enabled))
            #expect(receipt.wasEnabled == enabled)
            #expect(receipt.wasLoaded == loaded)
            try await actions.restore(receipt)
            #expect(privileged.recorded == ["remove \(plist)", "restore /backup\(plist)"])
            #expect(runner.calls.isEmpty)
        }
    }

    /// #166: Entladen und Entfernen eines Daemons sind **ein** Helper-Aufruf; ob entladen wurde, meldet der Helper.
    @Test func removingAndRestoringDaemonGoesEntirelyThroughHelper() async throws {
        let plist = "/Library/LaunchDaemons/com.docker.helper.plist"
        let runner = MockCommandRunner()
        let privileged = RecordingPrivileged(restoredPath: plist, unloads: true)
        let actions = actions(runner, privileged)
        let receipt = try await actions.remove(item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: plist, loaded: false))
        #expect(receipt.isPrivileged)
        #expect(receipt.wasLoaded)
        try await actions.restore(receipt)
        #expect(privileged.recorded == ["remove \(plist)", "restore /backup\(plist)", "bootstrap \(plist)"])
        // Die App fragt launchd weder beim Entfernen (das tut der Helper) noch beim Wiederherstellen.
        #expect(runner.calls.isEmpty)
    }

    @Test func removingAndRestoringUserAgentUsesUserBackupStore() async throws {
        try await ScratchDirectory.with { home in
            let agents = home.appending(path: "Library/LaunchAgents")
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: agents)
            let canonical = plist.resolvingSymlinksInPath().path
            let runner = MockCommandRunner([
                Self.probe("com.example.agent"): Self.loaded(from: plist.path),
                "/bin/launchctl bootout gui/501 \(plist.path)": Self.ok,
                "/bin/launchctl bootstrap gui/501 \(canonical)": Self.ok,
            ])
            let privileged = RecordingPrivileged()
            let actions = actions(runner, privileged, home: home.path)

            let receipt = try await actions.remove(item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true))
            #expect(!FileManager.default.fileExists(atPath: plist.path))
            #expect(FileManager.default.fileExists(atPath: receipt.backupPath))
            #expect(!receipt.isPrivileged)

            try await actions.restore(receipt)
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(runner.calls == [
                Self.probe("com.example.agent"), "/bin/launchctl bootout gui/501 \(plist.path)", "/bin/launchctl bootstrap gui/501 \(canonical)",
            ])
            #expect(privileged.recorded.isEmpty)
        }
    }

    /// Ein als Apple getarnter Benutzer-Agent (unsigniertes Programm außerhalb der Apple-Pfade) lässt sich entfernen
    /// und wiederherstellen.
    @Test func disguisedAppleUserAgentCanBeRemovedAndRestored() async throws {
        try await ScratchDirectory.with { home in
            let label = "com.apple.update.agent"
            let plist = try LaunchdPlistFixture.write(label: label, in: home.appending(path: "Library/LaunchAgents"))
            let runner = MockCommandRunner([
                Self.probe(label): Self.loaded(from: plist.path),
                "/bin/launchctl bootout gui/501 \(plist.path)": Self.ok,
                "/bin/launchctl bootstrap gui/501 \(plist.resolvingSymlinksInPath().path)": Self.ok,
            ])
            var disguised = item(label, kind: .launchAgent, domain: .user, plist: plist.path, loaded: true)
            disguised.program = home.appending(path: "Library/.x/agent").path
            disguised.programSigning = SigningInfo(kind: .unsigned)
            let actions = actions(runner, home: home.path)

            let receipt = try await actions.remove(disguised)
            #expect(!FileManager.default.fileExists(atPath: plist.path))
            try await actions.restore(receipt)
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    @Test func failedGuiBootoutOfSystemAgentStopsBeforeRemovePlist() async throws {
        try await ScratchDirectory.with { directory in
            let plist = try LaunchdPlistFixture.write(label: "com.vendor.agent", in: directory).path
            let runner = MockCommandRunner([
                Self.probe("com.vendor.agent"): Self.loaded(from: plist),
                "/bin/launchctl bootout gui/501 \(plist)": CommandResult(exitCode: 5, stdout: "", stderr: "busy"),
            ])
            let privileged = RecordingPrivileged()
            await #expect(throws: ActionError.self) {
                _ = try await actions(runner, privileged).remove(item("com.vendor.agent", kind: .launchAgent, domain: .system, plist: plist, loaded: true))
            }
            #expect(privileged.recorded.isEmpty)
        }
    }

    /// Die Meldung des Helpers – auch die seines Rollbacks (#166) – kommt unverändert an; die App lädt nichts selbst.
    @Test func failedDaemonRemovalInTheHelperIsReported() async {
        let plist = "/Library/LaunchDaemons/com.docker.helper.plist"
        let message = UnloadedRemovalFailure(path: plist, reason: "ersetzt", reloadFailure: nil).readableDescription
        let privileged = RecordingPrivileged(failure: HelperClientError.rejected(message))
        let runner = MockCommandRunner()
        await #expect(throws: ActionError.commandFailed(message)) {
            _ = try await actions(runner, privileged).remove(
                item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: plist, loaded: true))
        }
        #expect(privileged.recorded == ["remove \(plist)"])
        #expect(runner.calls.isEmpty)
    }

    @Test func failedBootoutKeepsUserPlist() async throws {
        try await ScratchDirectory.with { home in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: home.appending(path: "Library/LaunchAgents"))
            let runner = MockCommandRunner([
                Self.probe("com.example.agent"): Self.loaded(from: plist.path),
                "/bin/launchctl bootout gui/501 \(plist.path)": CommandResult(exitCode: 5, stdout: "", stderr: "busy"),
            ])
            await #expect(throws: ActionError.self) {
                _ = try await actions(runner, home: home.path).remove(
                    item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true))
            }
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    /// #98: Wird `~/Library/LaunchAgents` während des `bootout` gegen einen Symlink auf ein fremdes Verzeichnis
    /// getauscht, trifft die Löschung weiterhin nur die gesicherte Datei – nie die gleichnamige Fremddatei.
    @Test func directorySwapDuringBootoutNeverDeletesForeignFile() async throws {
        try await ScratchDirectory.with { home in
            let agents = home.appending(path: "Library/LaunchAgents")
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: agents)
            let movedAside = home.appending(path: "Library/LaunchAgents.moved")
            let victim = try LaunchdPlistFixture.write(label: "com.example.agent", in: home.appending(path: "victim"))
            let bootout = "/bin/launchctl bootout gui/501 \(plist.path)"
            let runner = SideEffectCommandRunner(
                MockCommandRunner([Self.probe("com.example.agent"): Self.loaded(from: plist.path), bootout: Self.ok]),
                on: bootout
            ) {
                try FileManager.default.moveItem(at: agents, to: movedAside)
                try FileManager.default.createSymbolicLink(at: agents, withDestinationURL: victim.deletingLastPathComponent())
            }

            let receipt = try await actions(runner, home: home.path).remove(
                item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true))
            #expect(FileManager.default.fileExists(atPath: victim.path))
            #expect(!FileManager.default.fileExists(atPath: movedAside.appending(path: "com.example.agent.plist").path))
            #expect(FileManager.default.fileExists(atPath: receipt.backupPath))
        }
    }

    /// #98: Wird die Plist während des `bootout` ersetzt, wird nichts gelöscht. #166: Eine Ersatzkonfiguration – mit
    /// gleichem oder anderem Label – lädt die App nicht; die Meldung sagt, dass der Dienst gestoppt bleibt.
    @Test(arguments: ["com.example.agent", "com.example.other"])
    func replacedUserPlistDuringBootoutIsNeitherDeletedNorLoaded(replacementLabel: String) async throws {
        try await ScratchDirectory.with { home in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: home.appending(path: "Library/LaunchAgents"))
            let (launchctl, runner) = Self.unloadedDuringBootout("com.example.agent", plist: plist.path) {
                try FileManager.default.removeItem(at: plist)
                try LaunchdPlistFixture.write(payload: ["Label": replacementLabel, "New": true], named: plist.lastPathComponent, in: plist.deletingLastPathComponent())
            }
            await #expect(throws: Self.userRemovalFailure(plist, reloadFailure: ServiceReloadError.plistReplaced.readableDescription)) {
                _ = try await actions(runner, home: home.path).remove(
                    item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true))
            }
            #expect(launchctl.calls == [Self.probe("com.example.agent"), "/bin/launchctl bootout gui/501 \(plist.path)"])
            let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            #expect(current?["New"] as? Bool == true)
        }
    }

    /// #166: Lässt sich die Benutzer-Plist nach dem `bootout` nicht löschen, liegen dort aber noch genau die gesicherten
    /// Bytes (neu geschrieben, andere Inode), lädt die App den Agenten wieder – bestätigt durch launchd. Wird sie
    /// dagegen während der Rollback-Abfrage ersetzt, lädt sie nichts.
    @Test(arguments: [false, true])
    func userAgentWithUnchangedBytesIsReloadedUnlessReplacedDuringTheRollbackQuery(replacedDuringQuery: Bool) async throws {
        try await ScratchDirectory.with { home in
            let plist = try LaunchdPlistFixture.write(label: "x", in: home.appending(path: "Library/LaunchAgents"))
            let (launchctl, runner) = Self.unloadedDuringBootout("x", plist: plist.path, duringRollbackQuery: {
                if replacedDuringQuery { try LaunchdPlistFixture.overwriteInPlace(plist, payload: ["Label": "x", "New": true]) }
            }) {
                let data = try Data(contentsOf: plist)
                try FileManager.default.removeItem(at: plist)
                try data.write(to: plist)
            }
            await #expect(throws: Self.userRemovalFailure(
                plist, reloadFailure: replacedDuringQuery ? ServiceReloadError.plistReplaced.readableDescription : nil
            )) {
                _ = try await actions(runner, home: home.path).remove(item("x", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true))
            }
            #expect(launchctl.calls == (replacedDuringQuery
                ? [Self.probe("x"), "/bin/launchctl bootout gui/501 \(plist.path)", Self.probe("x")]
                : Self.bootoutAndReload("x", plist: plist.path)))
        }
    }

    /// #166, Codex-Runde 6: Gleiche Bytes neu geschrieben während des `bootout` (Löschen scheitert), dann während der
    /// Rollback-Abfrage `LaunchAgents` umbenannt und am Originalpfad ein neues Verzeichnis mit einer anderen Plist
    /// gleichen Labels angelegt: Die alte Datei im gehaltenen Deskriptor ist unverändert, der Bootstrap-Pfad führt aber
    /// woandershin – kein `bootstrap`, `plistReplaced`. Für Benutzer- und Systemagenten.
    @Test(arguments: [AutostartDomain.user, .system])
    func directoryReplacedDuringTheRollbackQueryIsNotLoaded(domain: AutostartDomain) async throws {
        try await ScratchDirectory.with { home in
            let agents = home.appending(path: "Library/LaunchAgents")
            let plist = try LaunchdPlistFixture.write(label: "x", in: agents)
            let (launchctl, runner) = Self.unloadedDuringBootout("x", plist: plist.path, duringRollbackQuery: {
                try FileManager.default.moveItem(at: agents, to: home.appending(path: "Library/LaunchAgents.old"))
                try LaunchdPlistFixture.write(payload: ["Label": "x", "ProgramArguments": ["/usr/bin/true", "--other"]], named: "x.plist", in: agents)
            }) {
                let data = try Data(contentsOf: plist)
                try FileManager.default.removeItem(at: plist)
                try data.write(to: plist)
            }
            let refusal = "Datei seit der Sicherung ersetzt – bitte neu scannen"
            let privileged = RecordingPrivileged(failure: HelperClientError.rejected(refusal))
            let reason = domain == .user ? BackupError.sourceChanged(plist.resolvingSymlinksInPath().path).readableDescription : refusal

            await #expect(throws: UnloadedRemovalFailure(
                path: plist.path, reason: reason, reloadFailure: ServiceReloadError.plistReplaced.readableDescription
            )) {
                _ = try await actions(runner, privileged, home: home.path).remove(item("x", kind: .launchAgent, domain: domain, plist: plist.path, loaded: true))
            }
            #expect(launchctl.calls == [Self.probe("x"), "/bin/launchctl bootout gui/501 \(plist.path)", Self.probe("x")])
        }
    }

    /// launchctl für den geladenen Agenten `label` aus `plist`: Während des `bootout` läuft `duringBootout`, danach
    /// meldet launchd ihn als nicht geladen; während der Rollback-Abfrage läuft `duringRollbackQuery`; `bootstrap`
    /// gelingt und launchd meldet ihn danach wieder aus `plist` geladen. Liefert den protokollierenden Mock und den
    /// Runner mit Effekten.
    private static func unloadedDuringBootout(
        _ label: String, plist: String,
        duringRollbackQuery: @escaping SideEffectCommandRunner.Effect = {},
        _ duringBootout: @escaping SideEffectCommandRunner.Effect
    ) -> (launchctl: MockCommandRunner, runner: SideEffectCommandRunner) {
        let bootout = "/bin/launchctl bootout gui/501 \(plist)"
        let bootstrap = "/bin/launchctl bootstrap gui/501 \(plist)"
        let launchctl = MockCommandRunner([probe(label): loaded(from: plist), bootout: ok, bootstrap: ok])
        let script: [(commandLine: String, effect: SideEffectCommandRunner.Effect)] = [
            (probe(label), {}),
            (bootout, {
                try duringBootout()
                launchctl.stub(probe(label), notLoaded)
            }),
            (probe(label), duringRollbackQuery),
            (bootstrap, { launchctl.stub(probe(label), loaded(from: plist)) }),
        ]
        let runner = SideEffectCommandRunner(launchctl, script: script)
        return (launchctl, runner)
    }

    /// Befehlsfolge: Abfrage, `bootout`, erneute Abfrage, `bootstrap` und – nach gelungenem `bootstrap` – die
    /// bestätigende Abfrage (Rollback, #166).
    private static func bootoutAndReload(_ label: String, plist: String, bootstrapSucceeds: Bool = true) -> [String] {
        [probe(label), "/bin/launchctl bootout gui/501 \(plist)", probe(label), "/bin/launchctl bootstrap gui/501 \(plist)"]
            + (bootstrapSucceeds ? [probe(label)] : [])
    }

    /// Erwartete Meldung, wenn die Benutzer-Plist `plist` nach dem `bootout` nicht gelöscht wurde.
    private static func userRemovalFailure(_ plist: URL, reloadFailure: String?) -> UnloadedRemovalFailure {
        UnloadedRemovalFailure(
            path: plist.path, reason: BackupError.sourceChanged(plist.resolvingSymlinksInPath().path).readableDescription,
            reloadFailure: reloadFailure
        )
    }

    /// #156, Codex-Runde 3: Wird die Plist während des `bootout` in-place umgeschrieben (gleiche Inode), bleiben die
    /// neuen Bytes erhalten – die Sicherung enthält nur die alte Fassung. Mit wie ohne Fingerabdruck aus dem Scan.
    /// #166: Die umgeschriebene Fassung wird nicht geladen.
    @Test(arguments: [false, true])
    func userPlistRewrittenInPlaceDuringBootoutIsNotDeleted(withScanFingerprint: Bool) async throws {
        try await ScratchDirectory.with { home in
            let plist = try LaunchdPlistFixture.write(label: "x", in: home.appending(path: "Library/LaunchAgents"))
            let original = try Data(contentsOf: plist)
            var scanned = item("x", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true)
            if withScanFingerprint { scanned.plistFingerprint = try #require(FileFingerprint(of: plist.path)) }
            let (launchctl, runner) = Self.unloadedDuringBootout("x", plist: plist.path) {
                try LaunchdPlistFixture.overwriteInPlace(plist, payload: ["Label": "x", "New": true])
            }

            await #expect(throws: Self.userRemovalFailure(plist, reloadFailure: ServiceReloadError.plistReplaced.readableDescription)) {
                _ = try await actions(runner, home: home.path).remove(scanned)
            }
            #expect(launchctl.calls == [Self.probe("x"), "/bin/launchctl bootout gui/501 \(plist.path)"])
            let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            #expect(current?["New"] as? Bool == true)
            #expect(try backups(in: home).map { try Data(contentsOf: $0) } == [original])
        }
    }

    /// #156, Codex-Runde 3: Ersetzt ein Updater die Plist, während die App die Bindung bei launchd prüft
    /// (`launchctl print`, nach der Vorprüfung), sichert und löscht die App die Ersatzdatei nicht: Gesichert wird nur
    /// eine Datei mit dem Fingerabdruck aus dem Scan.
    @Test func userPlistReplacedWhileProbingIsNeitherBackedUpNorDeleted() async throws {
        try await ScratchDirectory.with { home in
            let agents = home.appending(path: "Library/LaunchAgents")
            let plist = try LaunchdPlistFixture.write(label: "x", in: agents)
            var scanned = item("x", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true)
            scanned.plistFingerprint = try #require(FileFingerprint(of: plist.path))
            let launchctl = MockCommandRunner([Self.probe("x"): Self.loaded(from: plist.path)])
            let runner = SideEffectCommandRunner(launchctl, on: Self.probe("x")) {
                let replacement = try LaunchdPlistFixture.write(payload: ["Label": "x", "New": true], named: "x.new", in: agents)
                _ = try FileManager.default.replaceItemAt(plist, withItemAt: replacement)
            }

            await #expect(throws: ActionError.notAllowed(.plistChanged)) {
                _ = try await actions(runner, home: home.path).remove(scanned)
            }
            #expect(launchctl.calls == [Self.probe("x")])
            let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
            #expect(current?["New"] as? Bool == true)
            #expect(try backups(in: home).isEmpty)
        }
    }

    /// #166: Ersetzt ein Updater die Plist eines Systemagenten, während die App launchd fragt, wird vor dem `bootout`
    /// abgelehnt – der Agent bleibt geladen, der Helper wird nicht bemüht.
    @Test func systemAgentReplacedWhileProbingIsRefusedBeforeBootout() async throws {
        try await ScratchDirectory.with { directory in
            let plist = try LaunchdPlistFixture.write(label: "x", in: directory)
            var scanned = item("x", kind: .launchAgent, domain: .system, plist: plist.path, loaded: true)
            scanned.plistFingerprint = try #require(FileFingerprint(of: plist.path))
            let launchctl = MockCommandRunner([Self.probe("x"): Self.loaded(from: plist.path), "/bin/launchctl bootout gui/501 \(plist.path)": Self.ok])
            let runner = SideEffectCommandRunner(launchctl, on: Self.probe("x")) {
                try LaunchdPlistFixture.overwriteInPlace(plist, payload: ["Label": "x", "New": true])
            }
            let privileged = RecordingPrivileged()

            await #expect(throws: ActionError.notAllowed(.plistChanged)) {
                _ = try await actions(runner, privileged).remove(scanned)
            }
            #expect(launchctl.calls == [Self.probe("x")])
            #expect(privileged.recorded.isEmpty)
        }
    }

    /// #166: Lehnt der Helper das Löschen nach dem `bootout` der App **bestätigt** ab und liegen am Pfad noch genau die
    /// geprüften Bytes, lädt die App den Systemagenten wieder; scheitert das, sagt die Meldung, dass er gestoppt bleibt.
    @Test(arguments: [true, false])
    func systemAgentIsReloadedWhenTheHelperRefusesRemovalAfterBootout(reloadSucceeds: Bool) async throws {
        try await ScratchDirectory.with { directory in
            let plist = try LaunchdPlistFixture.write(label: "com.vendor.agent", in: directory).path
            let refusal = "Sicherung nicht vertrauenswürdig"
            let (launchctl, runner) = Self.unloadedDuringBootout("com.vendor.agent", plist: plist) {}
            if !reloadSucceeds {
                launchctl.stub("/bin/launchctl bootstrap gui/501 \(plist)", CommandResult(exitCode: 5, stdout: "", stderr: "Input/output error"))
            }
            let privileged = RecordingPrivileged(failure: HelperClientError.rejected(refusal))

            await #expect(throws: UnloadedRemovalFailure(
                path: plist, reason: refusal,
                reloadFailure: reloadSucceeds ? nil : "launchctl bootstrap gui/501 \(plist) fehlgeschlagen (Exit 5): Input/output error"
            )) {
                _ = try await actions(runner, privileged).remove(item("com.vendor.agent", kind: .launchAgent, domain: .system, plist: plist, loaded: true))
            }
            #expect(launchctl.calls == Self.bootoutAndReload("com.vendor.agent", plist: plist, bootstrapSucceeds: reloadSucceeds))
            #expect(privileged.recorded == ["remove \(plist)"])
        }
    }

    /// #166, Codex-Runde 5: Ersetzt ein Updater die Plist eines Systemagenten während des `bootout` – auch mit gleichem
    /// Label und anderen Programmargumenten –, lädt die App die Ersatzkonfiguration nicht.
    @Test(arguments: ["x", "com.example.other"])
    func systemAgentReplacedDuringBootoutIsNotLoaded(replacementLabel: String) async throws {
        try await ScratchDirectory.with { directory in
            let plist = try LaunchdPlistFixture.write(label: "x", in: directory)
            let (launchctl, runner) = Self.unloadedDuringBootout("x", plist: plist.path) {
                try FileManager.default.removeItem(at: plist)
                try LaunchdPlistFixture.write(
                    payload: ["Label": replacementLabel, "ProgramArguments": ["/usr/bin/true", "--other"]],
                    named: plist.lastPathComponent, in: directory
                )
            }
            let refusal = "Datei seit der Sicherung ersetzt – bitte neu scannen"
            let privileged = RecordingPrivileged(failure: HelperClientError.rejected(refusal))

            await #expect(throws: UnloadedRemovalFailure(
                path: plist.path, reason: refusal, reloadFailure: ServiceReloadError.plistReplaced.readableDescription
            )) {
                _ = try await actions(runner, privileged).remove(item("x", kind: .launchAgent, domain: .system, plist: plist.path, loaded: true))
            }
            #expect(launchctl.calls == [Self.probe("x"), "/bin/launchctl bootout gui/501 \(plist.path)"])
        }
    }

    /// #166, Codex-Runde 4: Kennt der Helper `unloadAndRemovePlist` nicht (Protokoll 7) oder ist er nicht erreichbar,
    /// bricht das Entfernen eines Systemagenten ab, bevor die App ihn entlädt.
    @Test(arguments: [
        Result<Int, HelperClientError>.success(HelperXPC.unloadAndRemovePlistMinimumVersion - 1), .failure(.unavailable("weg")),
    ])
    func systemAgentRemovalWithAnOutdatedHelperStopsBeforeBootout(version: Result<Int, HelperClientError>) async {
        let plist = "/Library/LaunchAgents/com.vendor.agent.plist"
        let runner = MockCommandRunner([Self.probe("com.vendor.agent"): Self.loaded(from: plist), "/bin/launchctl bootout gui/501 \(plist)": Self.ok])
        let privileged = RecordingPrivileged(version: version)
        let expected = (try? version.get()) != nil ? HelperClientError.outdated : HelperClientError.unavailable("weg")
        await #expect(throws: ActionError.commandFailed(expected.readableDescription)) {
            _ = try await actions(runner, privileged).remove(item("com.vendor.agent", kind: .launchAgent, domain: .system, plist: plist, loaded: true))
        }
        #expect(runner.calls.isEmpty)
        #expect(privileged.recorded.isEmpty)
    }

    /// #166, Codex-Runde 5: Unbekannter Ausgang nach dem `bootout` – Abbruch oder Zeitüberschreitung/Verbindungsabbruch
    /// des Helper-Aufrufs, dessen Auftrag noch laufen kann – wird nicht kompensiert: kein Rollback, Abbruch unverändert,
    /// sonst „Ergebnis unbekannt – bitte neu scannen“.
    @Test(arguments: [true, false])
    func unknownOutcomeAfterBootoutIsNotRolledBack(cancelled: Bool) async throws {
        try await ScratchDirectory.with { directory in
            let plist = try LaunchdPlistFixture.write(label: "com.vendor.agent", in: directory).path
            let (launchctl, runner) = Self.unloadedDuringBootout("com.vendor.agent", plist: plist) {}
            let timeout = HelperClientError.unavailable("Zeitüberschreitung nach 105 s")
            let privileged = RecordingPrivileged(failure: cancelled ? CancellationError() : timeout)
            let systemAgent = item("com.vendor.agent", kind: .launchAgent, domain: .system, plist: plist, loaded: true)
            if cancelled {
                await #expect(throws: CancellationError.self) { _ = try await actions(runner, privileged).remove(systemAgent) }
            } else {
                await #expect(throws: UnloadedRemovalOutcomeUnknown(path: plist, reason: timeout.readableDescription)) {
                    _ = try await actions(runner, privileged).remove(systemAgent)
                }
            }
            #expect(launchctl.calls == [Self.probe("com.vendor.agent"), "/bin/launchctl bootout gui/501 \(plist)"])
        }
    }

    /// Alle Plist-Sicherungen im Benutzer-Speicher unter `home`.
    private func backups(in home: URL) throws -> [URL] {
        let root = PlistBackupStore.user(home: home.path).root
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "plist" }
    }

    /// #101: Wäre das Backup nicht wiederherstellbar (hier: gruppenbeschreibbarer Backup-Root), wird weder entladen
    /// noch gelöscht.
    /// Die Plist muss noch die aus dem Scan sein (#156, Codex-Nachprüfung): Hat ein Updater sie seither ersetzt oder
    /// umgeschrieben, ist der Eintrag ein anderer – nichts wird entladen, gesichert oder gelöscht.
    @Test func userPlistChangedSinceTheScanIsRefusedBeforeAnything() async throws {
        try await ScratchDirectory.with { home in
            let plist = try LaunchdPlistFixture.write(label: "x", in: home.appending(path: "Library/LaunchAgents"))
            var scanned = item("x", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true)
            scanned.plistFingerprint = try #require(FileFingerprint(of: plist.path))
            try LaunchdPlistFixture.write(payload: ["Label": "x", "Program": "/bin/ls"], named: "x.plist",
                                          in: plist.deletingLastPathComponent())
            let runner = MockCommandRunner([Self.probe("x"): Self.loaded(from: plist.path)])

            await #expect(throws: ActionError.notAllowed(.plistChanged)) {
                try await actions(runner, home: home.path).remove(scanned)
            }
            #expect(runner.calls.isEmpty)
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: plist.deletingLastPathComponent().path) == ["x.plist"])
        }
    }

    /// Dasselbe für Einträge, die der Helper löscht: Die App prüft den Fingerabdruck, bevor sie den Helper ruft.
    @Test func systemPlistChangedSinceTheScanIsRefusedBeforeTheHelper() async throws {
        try await ScratchDirectory.with { directory in
            let plist = try LaunchdPlistFixture.write(label: "x", in: directory)
            var scanned = item("x", kind: .launchDaemon, domain: .system, plist: plist.path, loaded: true)
            scanned.plistFingerprint = try #require(FileFingerprint(of: plist.path))
            try LaunchdPlistFixture.write(payload: ["Label": "x", "Program": "/bin/ls"], named: "x.plist", in: directory)
            let runner = MockCommandRunner([Self.systemProbe("x"): Self.loaded(from: plist.path)])
            let privileged = RecordingPrivileged()

            await #expect(throws: ActionError.notAllowed(.plistChanged)) {
                try await actions(runner, privileged).remove(scanned)
            }
            #expect(runner.calls.isEmpty)
            #expect(privileged.recorded.isEmpty)
        }
    }

    /// #156, Codex-Runde 3: Den Fingerabdruck aus dem Scan erhält auch der Helper – er bindet die Sicherung daran und
    /// prüft vor dem Löschen Identität und Inhalt (System-Domain).
    @Test func systemRemovalHandsTheScanFingerprintToTheHelper() async throws {
        try await ScratchDirectory.with { directory in
            let plist = try LaunchdPlistFixture.write(label: "x", in: directory)
            var scanned = item("x", kind: .launchDaemon, domain: .system, plist: plist.path, loaded: false)
            let fingerprint = try #require(FileFingerprint(of: plist.path))
            scanned.plistFingerprint = fingerprint
            let privileged = RecordingPrivileged()
            _ = try await actions(MockCommandRunner([Self.systemProbe("x"): Self.notLoaded]), privileged).remove(scanned)
            #expect(privileged.recorded == ["remove \(plist.path)"])
            #expect(privileged.expectedFingerprints.withLock { $0 } == [fingerprint])
        }
    }

    /// Mit unverändertem Fingerabdruck läuft das Entfernen wie gewohnt; ohne gespeicherten Fingerabdruck entfällt die
    /// Prüfung (ältere Snapshots, andere Quellen).
    @Test func unchangedOrUnknownFingerprintDoesNotBlockRemoval() async throws {
        try await ScratchDirectory.with { home in
            let agents = home.appending(path: "Library/LaunchAgents")
            let unchanged = try LaunchdPlistFixture.write(label: "x", in: agents)
            var scanned = item("x", kind: .launchAgent, domain: .user, plist: unchanged.path, loaded: false)
            scanned.plistFingerprint = try #require(FileFingerprint(of: unchanged.path))
            let unknown = try LaunchdPlistFixture.write(label: "y", in: agents)
            let legacy = item("y", kind: .launchAgent, domain: .user, plist: unknown.path, loaded: false)
            let runner = MockCommandRunner([Self.probe("x"): Self.notLoaded, Self.probe("y"): Self.notLoaded])

            _ = try await actions(runner, home: home.path).remove(scanned)
            _ = try await actions(runner, home: home.path).remove(legacy)
            #expect(!FileManager.default.fileExists(atPath: unchanged.path))
            #expect(!FileManager.default.fileExists(atPath: unknown.path))
        }
    }

    @Test func userAgentStaysWhenBackupWouldNotBeRestorable() async throws {
        try await ScratchDirectory.with { home in
            let plist = try LaunchdPlistFixture.write(label: "com.example.agent", in: home.appending(path: "Library/LaunchAgents"))
            let root = PlistBackupStore.user(home: home.path).root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o770])
            let runner = MockCommandRunner([
                Self.probe("com.example.agent"): Self.loaded(from: plist.path),
                "/bin/launchctl bootout gui/501 \(plist.path)": Self.ok,
            ])
            await #expect(throws: BackupError.untrustedStore(root.resolvingSymlinksInPath().path)) {
                _ = try await actions(runner, home: home.path).remove(
                    item("com.example.agent", kind: .launchAgent, domain: .user, plist: plist.path, loaded: true))
            }
            #expect(FileManager.default.fileExists(atPath: plist.path))
            #expect(runner.calls == [Self.probe("com.example.agent")])
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func symlinkedUserPlistIsRefusedBeforeAnythingChanges() async throws {
        try await ScratchDirectory.with { home in
            let agents = home.appending(path: "Library/LaunchAgents")
            let real = try LaunchdPlistFixture.write(label: "com.example.real", in: agents)
            let link = agents.appending(path: "com.example.agent.plist")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let runner = MockCommandRunner()
            await #expect(throws: PolicyViolation.self) {
                _ = try await actions(runner, home: home.path).remove(
                    item("com.example.agent", kind: .launchAgent, domain: .user, plist: link.path, loaded: true))
            }
            #expect(FileManager.default.fileExists(atPath: real.path))
            #expect(runner.calls.isEmpty)
        }
    }

    @Test func receiptRoundTripsThroughCodable() throws {
        let receipt = RemovalReceipt(label: "com.vendor.agent", backupPath: "/b/x.plist", isPrivileged: true, wasEnabled: false, wasLoaded: true)
        let decoded = try JSONDecoder().decode(RemovalReceipt.self, from: JSONEncoder().encode(receipt))
        #expect(decoded == receipt)
    }

    // MARK: - Ablehnungen und Fehler

    @Test func readOnlyItemsAreRefused() async {
        let runner = MockCommandRunner()
        let privileged = RecordingPrivileged()
        await #expect(throws: ActionError.notAllowed(.appleComponent)) {
            try await actions(runner, privileged).setEnabled(item("com.apple.foo", kind: .launchAgent, domain: .user, plist: "/x.plist", loaded: nil), false)
        }
        await #expect(throws: ActionError.notAllowed(.managedBySystemSettings)) {
            _ = try await actions(runner, privileged).remove(item("com.example.login", kind: .loginItem, domain: .user, plist: "/x.plist", loaded: nil))
        }
        #expect(runner.calls.isEmpty)
        #expect(privileged.recorded.isEmpty)
    }

    @Test func invalidLabelIsRefusedBeforeLaunchctl() async {
        let runner = MockCommandRunner()
        await #expect(throws: PolicyViolation.invalidLabel("-x evil")) {
            try await actions(runner).setEnabled(item("-x evil", kind: .launchAgent, domain: .user, plist: "/Users/x/Library/LaunchAgents/a.plist", loaded: true), false)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func launchctlFailureIsReported() async {
        let runner = MockCommandRunner([
            Self.probe("com.example.agent"): Self.notLoaded,
            "/bin/launchctl disable gui/501/com.example.agent": CommandResult(exitCode: 1, stdout: "", stderr: "nope"),
        ])
        await #expect(throws: ActionError.commandFailed("launchctl disable gui/501/com.example.agent fehlgeschlagen (Exit 1): nope")) {
            try await actions(runner).setEnabled(item("com.example.agent", kind: .launchAgent, domain: .user, plist: "/Users/x/Library/LaunchAgents/a.plist", loaded: false), false)
        }
    }

    @Test func helperErrorsBecomeCommandFailures() async {
        let privileged = RecordingPrivileged(failure: HelperClientError.rejected("Pfad ist für diese Aktion nicht erlaubt"))
        let runner = MockCommandRunner([Self.systemProbe("com.docker.helper"): Self.loaded(from: "/Library/LaunchDaemons/com.docker.helper.plist")])
        await #expect(throws: ActionError.commandFailed("Pfad ist für diese Aktion nicht erlaubt")) {
            try await actions(runner, privileged).setEnabled(
                item("com.docker.helper", kind: .launchDaemon, domain: .system, plist: "/Library/LaunchDaemons/com.docker.helper.plist", loaded: true), false)
        }
        #expect(privileged.recorded == ["disable /Library/LaunchDaemons/com.docker.helper.plist"])
    }

    @Test func cancellationPropagatesUnchanged() async {
        let privileged = RecordingPrivileged(failure: CancellationError())
        await #expect(throws: CancellationError.self) {
            _ = try await actions(MockCommandRunner([Self.probe("com.vendor.agent"): Self.notLoaded]), privileged).remove(
                item("com.vendor.agent", kind: .launchAgent, domain: .system, plist: "/Library/LaunchAgents/com.vendor.agent.plist", loaded: false))
        }
    }
}
