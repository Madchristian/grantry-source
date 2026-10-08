import Foundation
import Testing
@testable import ManagerKit
import TestSupport

/// Plist-Identität vs. launchd-Dienstidentität (#138): Zwei Plists mit demselben Label in derselben Domain sind zwei
/// Einträge. Alles läuft in temporären Verzeichnissen mit Attrappen-Plists und gestubbtem launchctl.
@Suite struct LaunchdIdentityTests {
    private static let label = "com.example.twin"

    private static func plist(_ program: String) -> [String: Any] {
        ["Label": label, "Program": program]
    }

    private static func runner(domains: [String] = ["gui/501"]) -> MockCommandRunner {
        let runner = MockCommandRunner()
        for domain in domains {
            runner.stub("/bin/launchctl print-disabled \(domain)", CommandResult(exitCode: 0, stdout: "\n\tdisabled services = {\n\t}\n"))
            runner.stub("/bin/launchctl print \(domain)", CommandResult(exitCode: 0, stdout: "\(domain) = {\n\tservices = {\n\t}\n}\n"))
        }
        return runner
    }

    private static func scan(
        _ directories: [LaunchdDirectory], previous: Snapshot?, at date: Date
    ) async throws -> (snapshot: Snapshot, events: [ChangeEvent]) {
        let source = LaunchdSource(directories: directories, runner: runner(domains: ["gui/501", "system"]), resolver: StubAppResolver())
        let snapshot = try await ScanCoordinator(sources: [source], now: { date }).scan(previous: previous)
        return (snapshot, SnapshotDiffer().diff(from: previous, to: snapshot))
    }

    // MARK: - Inventar und Verlauf

    /// Die Reproduktion aus #138, für Benutzer-Agents, System-Agents und System-Daemons: `z.plist` mit demselben Label
    /// wie `a.plist`, aber anderem Befehl, wird als neu erkannt; ihre Entfernung ebenso. `a.plist` bleibt unberührt.
    @Test(arguments: [
        (AutostartKind.launchAgent, AutostartDomain.user, "gui/501"),
        (AutostartKind.launchAgent, AutostartDomain.system, "gui/501"),
        (AutostartKind.launchDaemon, AutostartDomain.system, "system"),
    ])
    func duplicateLabelInOneDirectoryIsASecondEntry(kind: AutostartKind, domain: AutostartDomain, launchctlDomain: String) async throws {
        try await ScratchDirectory.with(prefix: "launchd-twin") { directory in
            let directories = [LaunchdDirectory(path: directory.path, kind: kind, domain: domain, launchctlDomain: launchctlDomain)]
            try LaunchdPlistFixture.write(payload: Self.plist("/bin/ls"), named: "a.plist", in: directory)
            let first = try await Self.scan(directories, previous: nil, at: TestData.date)

            let twin = try LaunchdPlistFixture.write(payload: Self.plist("/bin/cat"), named: "z.plist", in: directory)
            let added = try await Self.scan(directories, previous: first.snapshot, at: TestData.date + 60)
            let items = added.snapshot.autostartItems
            #expect(items.count == 2)
            #expect(Set(items.map(\.id)).count == 2)
            #expect(Set(items.map(\.launchdServiceID)).count == 1)
            #expect(!added.snapshot.isEquivalent(to: first.snapshot))
            #expect(added.events.map(\.kind) == [.added])
            #expect(added.events.first?.after?.autostartItem?.plistPath == twin.path)

            try FileManager.default.removeItem(at: twin)
            let removed = try await Self.scan(directories, previous: added.snapshot, at: TestData.date + 120)
            #expect(removed.events.map(\.kind) == [.removed])
            #expect(removed.events.first?.before?.autostartItem?.plistPath == twin.path)
            #expect(removed.snapshot.autostartItems.map(\.id) == first.snapshot.autostartItems.map(\.id))
        }
    }

    /// Ändert sich nur die zweite Plist, betrifft das Ereignis genau sie – nicht die erste mit demselben Label.
    @Test func changeOfOneTwinIsReportedForThatFile() async throws {
        try await ScratchDirectory.with(prefix: "launchd-twin-change") { directory in
            let directories = [LaunchdDirectory(path: directory.path, kind: .launchAgent, domain: .user, launchctlDomain: "gui/501")]
            try LaunchdPlistFixture.write(payload: Self.plist("/bin/ls"), named: "a.plist", in: directory)
            let twin = try LaunchdPlistFixture.write(payload: Self.plist("/bin/cat"), named: "z.plist", in: directory)
            let first = try await Self.scan(directories, previous: nil, at: TestData.date)

            try LaunchdPlistFixture.write(payload: Self.plist("/bin/echo"), named: "z.plist", in: directory)
            let changed = try await Self.scan(directories, previous: first.snapshot, at: TestData.date + 60)
            #expect(changed.events.map(\.kind) == [.modified])
            #expect(changed.events.first?.after?.autostartItem?.plistPath == twin.path)
            #expect(changed.events.first?.after?.autostartItem?.program == "/bin/echo")
        }
    }

    // MARK: - IDs und Abwärtskompatibilität

    @Test func idKeepsTheLegacyFormForPlistsNamedAfterTheirLabel() {
        var canonical = TestData.item("com.example.agent")
        canonical.plistPath = "/Users/test/Library/LaunchAgents/com.example.agent.plist"
        #expect(canonical.id == "launchAgent|user|com.example.agent")
        #expect(canonical.distinctPlistName == nil)

        var other = canonical
        other.plistPath = "/Users/test/Library/LaunchAgents/z.plist"
        #expect(other.id == "launchAgent|user|com.example.agent/z.plist")
        #expect(other.distinctPlistName == "z.plist")
        #expect(other.launchdServiceID == canonical.launchdServiceID)
        #expect(canonical.launchdServiceID == "gui/com.example.agent")

        // Andere Quellen ohne Plist behalten ihre ID; BTM-Einträge haben keinen launchd-Dienst.
        let btm = TestData.item("com.example.agent", kind: .backgroundTask, source: .btm)
        var withoutPlist = btm
        withoutPlist.plistPath = nil
        #expect(withoutPlist.id == "backgroundTask|user|com.example.agent")
        #expect(btm.launchdServiceID == nil)
    }

    /// Ein Label mit `/` kann die ID einer anderen Plist nicht nachbilden: Hinter dem letzten `/` steht immer der
    /// vollständige Dateiname, und eine Plist `<label>.plist` hat kein `/` im Label.
    @Test func idsOfCraftedLabelsDoNotCollide() {
        var first = TestData.item("a/b")
        first.plistPath = "/Library/LaunchAgents/c.plist"
        var second = TestData.item("a")
        second.plistPath = "/Library/LaunchAgents/b.plist"
        var third = TestData.item("a")
        third.plistPath = "/Library/LaunchAgents/b|c.plist"
        var fourth = TestData.item("a/b|c")
        fourth.plistPath = "/Library/LaunchAgents/x.plist"
        let ids = [first, second, third, fourth, TestData.item("a")].map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// Ein vor #138 gespeicherter Snapshot (dieselben Felder, IDs ohne Dateinamen) dekodiert ohne Schein-Ereignisse:
    /// Die ID folgt aus den gespeicherten Feldern, auch für zwei Plists mit gleichem Label.
    @Test func storedSnapshotsDecodeWithoutSpuriousEvents() throws {
        var first = TestData.item(Self.label)
        first.plistPath = "/Users/test/Library/LaunchAgents/\(Self.label).plist"
        var twin = TestData.item(Self.label)
        twin.plistPath = "/Users/test/Library/LaunchAgents/z.plist"
        twin.program = "/bin/cat"
        let stored = TestData.snapshot(items: [first, twin])

        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(stored))
        let rescanned = TestData.snapshot(items: [first, twin], at: TestData.date + 60)

        #expect(decoded.autostartItems.map(\.id) == stored.autostartItems.map(\.id))
        #expect(decoded.autostartItems.first?.id == "launchAgent|user|\(Self.label)")
        #expect(SnapshotDiffer().diff(from: decoded, to: rescanned).isEmpty)
        #expect(decoded.isEquivalent(to: rescanned))
    }

    // MARK: - Findings und Darstellung

    @Test func findingsOfTwinsAreSeparate() {
        var first = TestData.item(Self.label, programPresence: .missing)
        first.plistPath = "/Library/LaunchAgents/\(Self.label).plist"
        var twin = first
        twin.plistPath = "/Library/LaunchAgents/z.plist"
        let findings = OrphanRule().evaluate(TestData.snapshot(items: [first, twin]))
        #expect(Set(findings.map(\.recordID)) == [first.id, twin.id])
        #expect(Set(findings.map(\.id)).count == 2)
    }

    @Test func presentationNamesTheOtherPlistsOfAService() {
        var first = TestData.item(Self.label)
        first.plistPath = "/Library/LaunchAgents/\(Self.label).plist"
        var twin = first
        twin.plistPath = "/Library/LaunchAgents/z.plist"
        let unrelated = TestData.item("com.example.alone")
        let presentation = PresentationSnapshot.make(
            snapshot: TestData.snapshot(items: [first, twin, unrelated]), findings: [], events: [], recentAdditions: [],
            now: TestData.date
        )
        #expect(presentation.autostartItems(sharingServiceWith: first).map(\.id) == [twin.id])
        #expect(presentation.autostartItems(sharingServiceWith: twin).map(\.id) == [first.id])
        #expect(presentation.autostartItems(sharingServiceWith: unrelated).isEmpty)
        #expect(presentation.autostartSections.flatMap(\.items).count == 3)

        let description = ChangeDescription(ChangeEvent(kind: .added, before: nil, after: .autostartItem(twin), detectedAt: TestData.date))
        #expect(description.body == "\(Self.label) (LaunchAgent, z.plist).")
    }

    // MARK: - Aktionen

    /// Aktivieren/Deaktivieren eines LaunchAgents wirkt über das Label (Override): Trägt eine weitere Plist in
    /// `gui/<uid>` dasselbe Label – im selben oder im anderen Agents-Verzeichnis –, lehnt die App ab, bevor launchctl
    /// läuft. Mit eindeutigem Label läuft die bisherige Prüfung (#99, #166) unverändert.
    @Test func overrideIsRefusedWhileAnotherPlistSharesTheLabel() async throws {
        try await ScratchDirectory.with(prefix: "launchd-twin-action") { home in
            let userAgents = home.appending(path: "Library/LaunchAgents")
            let systemAgents = home.appending(path: "SystemLaunchAgents")
            let own = try LaunchdPlistFixture.write(payload: Self.plist("/bin/ls"), named: "a.plist", in: userAgents)
            let twin = try LaunchdPlistFixture.write(payload: Self.plist("/bin/cat"), named: "z.plist", in: systemAgents)
            let runner = MockCommandRunner()
            let actions = AutostartActions(
                runner: runner, privileged: UnusedPrivileged(), userBackups: .user(home: home.path), uid: 501,
                launchAgentDirectories: [userAgents.path, systemAgents.path]
            )
            var item = TestData.item(Self.label, domain: .user)
            item.plistPath = own.path

            await #expect(throws: ActionError.notAllowed(.ambiguousLabel)) { try await actions.setEnabled(item, false) }
            #expect(runner.calls.isEmpty)

            try FileManager.default.removeItem(at: twin)
            runner.stub("/bin/launchctl print gui/501/\(Self.label)", CommandResult(exitCode: 113, stdout: "", stderr: "Could not find service"))
            runner.stub("/bin/launchctl disable gui/501/\(Self.label)", CommandResult(exitCode: 0, stdout: ""))
            try await actions.setEnabled(item, false)
            #expect(runner.calls == ["/bin/launchctl print gui/501/\(Self.label)", "/bin/launchctl disable gui/501/\(Self.label)"])
        }
    }

    /// Eine weitere Agent-Plist ohne Leserecht (`chmod 000`) könnte dasselbe Label tragen: Die App lehnt den Override ab,
    /// bevor launchctl läuft (fail-closed).
    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte"))
    func overrideIsRefusedWhileAnotherPlistIsUnreadable() async throws {
        try await ScratchDirectory.with(prefix: "launchd-twin-locked") { home in
            let userAgents = home.appending(path: "Library/LaunchAgents")
            let own = try LaunchdPlistFixture.write(payload: Self.plist("/bin/ls"), named: "a.plist", in: userAgents)
            let twin = try LaunchdPlistFixture.write(payload: Self.plist("/bin/cat"), named: "z.plist", in: userAgents)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: twin.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: twin.path) }
            let runner = MockCommandRunner()
            let actions = AutostartActions(
                runner: runner, privileged: UnusedPrivileged(), userBackups: .user(home: home.path), uid: 501,
                launchAgentDirectories: [userAgents.path]
            )
            var item = TestData.item(Self.label, domain: .user)
            item.plistPath = own.path

            await #expect(throws: PolicyViolation.unverifiableLabel(twin.resolvingSymlinksInPath().path)) {
                try await actions.setEnabled(item, true)
            }
            #expect(runner.calls.isEmpty)
        }
    }

    /// Fehlt das Suchrecht auf dem Elternverzeichnis eines Agents-Verzeichnisses, gilt es nicht als fehlend: Die App
    /// lehnt den Override ab, statt einen möglichen Zwilling darin zu übersehen.
    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte"))
    func overrideIsRefusedWhenAnAgentsDirectoryIsUnsearchable() async throws {
        try await ScratchDirectory.with(prefix: "launchd-twin-parent") { home in
            let own = try LaunchdPlistFixture.write(payload: Self.plist("/bin/ls"), named: "a.plist", in: home.appending(path: "Library/LaunchAgents"))
            let parent = home.appending(path: "Locked")
            let hidden = parent.appending(path: "LaunchAgents")
            try LaunchdPlistFixture.write(payload: Self.plist("/bin/cat"), named: "z.plist", in: hidden)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
            let runner = MockCommandRunner()
            let actions = AutostartActions(
                runner: runner, privileged: UnusedPrivileged(), userBackups: .user(home: home.path), uid: 501,
                launchAgentDirectories: [own.deletingLastPathComponent().path, hidden.path]
            )
            var item = TestData.item(Self.label, domain: .user)
            item.plistPath = own.path

            await #expect(throws: PolicyViolation.unreadableDirectory(hidden.path)) { try await actions.setEnabled(item, false) }
            #expect(runner.calls.isEmpty)
        }
    }

    /// Die Prüfung auf doppelte Labels liest nur reguläre Dateien: Eine FIFO mit Plist-Endung im Agents-Verzeichnis hält
    /// sie nicht an.
    @Test func labelCheckDoesNotBlockOnSpecialFiles() async throws {
        try await ScratchDirectory.with(prefix: "launchd-twin-fifo") { directory in
            let own = try LaunchdPlistFixture.write(payload: Self.plist("/bin/ls"), named: "a.plist", in: directory)
            let fifo = try FIFOFixture.make(in: directory, named: "fifo.plist")
            let path = directory.path
            let checked = await FIFOFixture.completes(unblocking: fifo) {
                (try? PrivilegedOperationPolicy().ensureLabelIsUnique(Self.label, ofPlistAt: own.path, in: [path])) != nil
            }
            #expect(checked == true)
        }
    }

    /// Die Wirkungsprüfung nach einer Aktion meint genau die bestätigte Datei: Der Zwilling mit demselben Label zählt nicht.
    @Test func actionChecksMatchThePlistNotTheLabel() async throws {
        var item = TestData.item(Self.label, isEnabled: true)
        item.plistPath = "/Library/LaunchAgents/\(Self.label).plist"
        var twin = item
        twin.plistPath = "/Library/LaunchAgents/z.plist"
        twin.isEnabled = false
        try await ScratchDirectory.withCanonical(prefix: "launchd-twin-check") { directory in
            func coordinator(scanning items: [AutostartItem]) -> ActionCoordinator {
                ActionCoordinator(
                    permissions: NoPermissions(), autostart: NoAutostart(), security: NoSecurity(),
                    receipts: ReceiptStore(url: directory.appending(path: "receipts.json")),
                    scanner: FixedScanner(snapshot: TestData.snapshot(items: items, at: .distantFuture)),
                    verificationTimeout: .seconds(1)
                )
            }
            // Deaktiviert ist nur der Zwilling: Das bestätigt nichts für `item`.
            #expect(await coordinator(scanning: [item, twin]).setEnabled(item, false) != .done)
            // Der Zwilling ist weg, `item` mit demselben Label bleibt: Das Entfernen des Zwillings ist bestätigt.
            #expect(await coordinator(scanning: [item]).remove(twin) == .done)
        }
    }
}

extension ChangeSubject {
    fileprivate var autostartItem: AutostartItem? {
        if case .autostartItem(let item) = self { item } else { nil }
    }
}

/// Darf nie aufgerufen werden: LaunchAgents laufen ohne Helper.
private struct UnusedPrivileged: PrivilegedAutostartControlling {
    func protocolVersion() async throws -> Int { Issue.record("Helper aufgerufen"); return 0 }
    func setEnabled(plistPath: String, enabled: Bool) async throws { Issue.record("Helper aufgerufen") }
    func bootout(plistPath: String) async throws { Issue.record("Helper aufgerufen") }
    func bootstrap(plistPath: String) async throws { Issue.record("Helper aufgerufen") }
    func unloadAndRemovePlist(path: String, expectedFingerprint: FileFingerprint?) async throws -> PrivilegedPlistRemoval {
        Issue.record("Helper aufgerufen")
        return PrivilegedPlistRemoval(backupPath: "", wasUnloaded: false)
    }
    func restorePlist(backupPath: String) async throws -> String { Issue.record("Helper aufgerufen"); return "" }
}

private struct NoPermissions: PermissionResetting {
    func reset(_ grant: PermissionGrant) async throws {}
    func resetService(_ service: String) async throws {}
}

private struct NoAutostart: AutostartControlling {
    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async throws {}
    func remove(_ item: AutostartItem) async throws -> RemovalReceipt {
        RemovalReceipt(label: item.label, backupPath: "/backup", isPrivileged: false, wasEnabled: true, wasLoaded: false)
    }
    func restore(_ receipt: RemovalReceipt) async throws {}
}

private struct NoSecurity: SecurityControlling {
    func perform(_ action: SecurityAction) async throws {}
}

private struct FixedScanner: ScanRequesting {
    let snapshot: Snapshot
    func scan(startedNotBefore date: Date) async -> Snapshot? { snapshot }
}
