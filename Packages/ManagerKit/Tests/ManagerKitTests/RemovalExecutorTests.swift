import Foundation
import GrantryShared
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

// Nur Attrappen: Kein Test spricht den Finder an oder löscht etwas; die Dateien liegen in einem Scratch-Ordner.

private final class Log: Sendable {
    private let entries = Mutex<[String]>([])
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

private struct Failure: LocalizedError {
    var errorDescription: String? { "Befehl fehlgeschlagen" }
}

private struct LoggingPermissions: PermissionResetting {
    let log: Log
    var failing: Set<String> = []
    func reset(_ grant: PermissionGrant) async throws {
        log.append("reset \(grant.service)")
        if failing.contains(grant.service) { throw Failure() }
    }
    func resetService(_ service: String) async throws { Issue.record("nicht erwartet") }
}

private struct LoggingAutostart: AutostartControlling {
    let log: Log
    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async throws { Issue.record("nicht erwartet") }
    func remove(_ item: AutostartItem) async throws -> RemovalReceipt {
        log.append("remove \(item.label)")
        return RemovalReceipt(label: item.label, backupPath: "/backups/\(item.label).plist", isPrivileged: false,
                              wasEnabled: true, wasLoaded: false)
    }
    func restore(_ receipt: RemovalReceipt) async throws { Issue.record("nicht erwartet") }
}

/// Papierkorb-Attrappe: protokolliert, ruft wie `FinderTrash` die letzte Prüfung je Kandidat auf (davor `beforeCheck`),
/// lässt `remaining` liegen, meldet `recreated` als neu angelegt, alle übrigen gelten als entfernt – ohne etwas anzufassen.
private final class LoggingTrash: TrashPerforming {
    let log: Log
    let permission: TrashPermission
    let remaining: [String: String]
    let recreated: Set<String>
    let beforeCheck: @Sendable () -> Void
    private let received = Mutex<[[String]]>([])

    init(
        log: Log, permission: TrashPermission = .granted, remaining: [String: String] = [:], recreated: Set<String> = [],
        beforeCheck: @escaping @Sendable () -> Void = {}
    ) {
        self.log = log
        self.permission = permission
        self.remaining = remaining
        self.recreated = recreated
        self.beforeCheck = beforeCheck
    }

    var calls: [[String]] { received.withLock { $0 } }

    func requestPermission() async -> TrashPermission {
        log.append("permission")
        return permission
    }

    func moveToTrash(
        _ candidates: [LeftoverCandidate], verifying verify: @escaping @Sendable (LeftoverCandidate) -> RemovalVerdict
    ) async -> TrashReport {
        let paths = candidates.map(\.path)
        log.append("trash \(paths.count)")
        received.withLock { $0.append(paths) }
        beforeCheck()
        let outcomes = candidates.map { candidate -> (String, TrashItemOutcome) in
            if case .blocked(let reason) = verify(candidate) { return (candidate.path, .blocked(reason)) }
            if recreated.contains(candidate.path) { return (candidate.path, .recreated) }
            return (candidate.path, remaining[candidate.path].map(TrashItemOutcome.remaining) ?? .trashed)
        }
        return TrashReport(outcomes: Dictionary(uniqueKeysWithValues: outcomes),
                           failure: remaining.isEmpty ? nil : "Abgebrochen (z. B. Passwortabfrage)")
    }
}

/// Liefert nacheinander `answers` (der letzte wiederholt sich).
private final class ScriptedRunning: RunningApplicationChecking {
    private let answers: Mutex<[Bool]>
    init(_ answers: [Bool]) { self.answers = Mutex(answers) }
    func isRunning(_ app: InstalledApp) async -> Bool {
        answers.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? false }
    }
}

/// Kandidat wie aus der Reste-Suche: mit dem Objekt (`FileIdentity`) zum Zeitpunkt der Suche.
private func candidate(_ path: String, kind: LeftoverKind, size: FileSize = .unknown) -> LeftoverCandidate {
    LeftoverCandidate(path: path, kind: kind, confidence: .safe, size: size, identity: FileIdentity.of(path))
}

@Suite struct RemovalExecutorTests {
    private let log = Log()

    private func executor(
        _ fixture: LibraryFixture, receipts: ReceiptStore, trash: LoggingTrash? = nil, running: [Bool] = [false],
        failingResets: Set<String> = [], current: Snapshot? = TestData.appSnapshot([])
    ) -> RemovalExecutor {
        let log = log
        return RemovalExecutor(
            permissions: LoggingPermissions(log: log, failing: failingResets), autostart: LoggingAutostart(log: log),
            receipts: receipts, trash: trash ?? LoggingTrash(log: log), runningApps: ScriptedRunning(running),
            removalGuard: RemovalGuard(layout: fixture.layout),
            currentSnapshot: {
                log.append("current")
                return current
            },
            now: { TestData.date }
        )
    }

    /// Aufräumen-Plan wie aus `RemovalPlanning.plan(cleanup:selection:)`: je Datei die Begründung der Suche.
    private func cleanupPlan(_ files: [(LeftoverCandidate, OrphanClaim)], autostartItems: [AutostartItem] = []) -> RemovalPlan {
        RemovalPlan(app: nil, grants: [], autostartItems: autostartItems, files: files.map(\.0),
                    orphanClaims: Dictionary(uniqueKeysWithValues: files.map { ($0.0.path, $0.1) }))
    }

    private func plan(
        _ fixture: LibraryFixture, name: String = "Tool", origin: AppOrigin = .direct, bundleID: String = "com.example.tool"
    ) throws -> RemovalPlan {
        let path = try fixture.app(name, bundleID: bundleID)
        let app = TestData.installedApp(name, bundleID: bundleID, path: path, origin: origin)
        let cache = try fixture.folder(fixture.userLibrary("Caches/\(bundleID)"))
        return RemovalPlan(
            app: app, grants: [TestData.grant(client: app.identity)],
            autostartItems: [TestData.item("\(bundleID).agent", owner: app.identity)],
            files: [candidate(path, kind: .appBundle, size: .bytes(10)), candidate(cache, kind: .caches, size: .bytes(5))]
        )
    }

    private func withReceipts<T>(_ body: (ReceiptStore) async throws -> T) async throws -> T {
        try await ScratchDirectory.withCanonical(prefix: "removal") { directory in
            try await body(ReceiptStore(url: directory.appending(path: "Receipts.json")))
        }
    }

    @Test func resetsThenRemovesAutostartThenTrashesInOneEvent() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let plan = try plan(fixture)
                let trash = LoggingTrash(log: log)
                let report = await executor(fixture, receipts: receipts, trash: trash).run(plan)
                #expect(log.all == [
                    "current", "permission", "reset kTCCServiceCamera", "remove com.example.tool.agent", "trash 2",
                ])
                #expect(trash.calls == [plan.files.map(\.path)])
                #expect(report.entries.count == 4)
                #expect(report.entries.allSatisfy { $0.result == .done })
                #expect(try await receipts.receipts().map(\.label) == ["com.example.tool.agent"])
            }
        }
    }

    /// Issue #102: Ein schon abgebrochener Plan (etwa noch eingereiht) beginnt keinen Schritt und fragt nichts an.
    @Test func abortedPlanChangesNothing() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let abort = OneShotSignal()
                abort.fire()
                let plan = try plan(fixture)
                let report = await executor(fixture, receipts: receipts).run(plan, abortedBy: abort)
                #expect(report == .skipping(plan, reason: RemovalExecutor.abortedReason))
                #expect(log.all.isEmpty)
            }
        }
    }

    @Test func runningAppChangesNothing() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let report = await executor(fixture, receipts: receipts, running: [true]).run(try plan(fixture))
                #expect(log.all.isEmpty)
                #expect(report.entries.count == 4)
                #expect(report.entries.allSatisfy { $0.result == .skipped("Tool läuft noch – bitte zuerst beenden.") })
            }
        }
    }

    @Test func missingAutomationPermissionChangesNothing() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let trash = LoggingTrash(log: log, permission: .denied)
                let report = await executor(fixture, receipts: receipts, trash: trash).run(try plan(fixture))
                #expect(log.all == ["current", "permission"])
                #expect(report.automationDenied)
                #expect(report.entries.allSatisfy { $0.result == .skipped(RemovalExecutor.automationDeniedReason) })
                #expect(try await receipts.receipts().isEmpty)
            }
        }
    }

    @Test func unavailableTrashChangesNothing() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let trash = LoggingTrash(log: log, permission: .unavailable("Finder läuft nicht."))
                let report = await executor(fixture, receipts: receipts, trash: trash).run(try plan(fixture))
                #expect(log.all == ["current", "permission"])
                #expect(!report.automationDenied)
                #expect(report.entries.allSatisfy { $0.result == .skipped("Finder läuft nicht.") })
            }
        }
    }

    @Test func homebrewCaskAndGrantryItselfAreNeverTouched() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let brew = await executor(fixture, receipts: receipts).run(try plan(fixture, origin: .homebrew(cask: "tool")))
                #expect(brew.entries.allSatisfy { $0.result == .skipped(RemovalRoute.homebrew(command: "brew uninstall --cask tool").reason ?? "") })
                // Eine Grantry-Kopie an anderem Ort als die laufende (#131).
                let own = await executor(fixture, receipts: receipts).run(try plan(fixture, name: "Grantry", bundleID: GrantryIdentity.appBundleID))
                #expect(own.entries.allSatisfy { $0.result == .skipped(RemovalRoute.otherGrantryCopy.reason ?? "") })
                #expect(log.all.isEmpty)
            }
        }
    }

    @Test func planWithoutFilesNeedsNoPermission() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let item = TestData.item("ai.openclaw.gateway", programPresence: .missing)
                let report = await executor(fixture, receipts: receipts)
                    .run(RemovalPlan(app: nil, grants: [], autostartItems: [item], files: []))
                #expect(log.all == ["current", "remove ai.openclaw.gateway"])
                #expect(report.entries.map(\.result) == [.done])
            }
        }
    }

    @Test func blockedPathNeverReachesTheTrash() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let keychain = try fixture.file(fixture.userLibrary("Keychains/login.keychain-db"))
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let trash = LoggingTrash(log: log)
                let plan = RemovalPlan(app: nil, grants: [], autostartItems: [], files: [
                    candidate(keychain, kind: .caches), candidate(cache, kind: .caches),
                ])
                let report = await executor(fixture, receipts: receipts, trash: trash).run(plan)
                #expect(log.all == ["permission", "trash 1"])
                #expect(trash.calls == [[cache]])
                #expect(report.entries.map(\.result) == [.failed("Nicht angefasst: Geschützter Ort"), .done])
            }
        }
    }

    /// Zwischen Suche und Ausführung ersetzt – oder ohne Identität aus der Suche: nie in den Papierkorb.
    @Test func replacedEntryNeverReachesTheTrash() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let found = candidate(cache, kind: .caches)
                try FileManager.default.removeItem(atPath: cache)
                try fixture.folder(cache)
                let prefs = try fixture.file(fixture.userLibrary("Preferences/com.example.tool.plist"))
                let unchecked = LeftoverCandidate(path: prefs, kind: .preferences, confidence: .safe)
                let plan = RemovalPlan(app: nil, grants: [], autostartItems: [], files: [found, unchecked])
                let report = await executor(fixture, receipts: receipts).run(plan)
                #expect(!log.all.contains { $0.hasPrefix("trash") })
                #expect(report.entries.map(\.result) == [
                    .failed("Nicht angefasst: Eintrag wurde ersetzt"), .failed("Nicht angefasst: Eintrag wurde ersetzt"),
                ])
            }
        }
    }

    /// Review N2: Wird ein Eintrag nach der Prüfung des Executors ersetzt, fängt ihn die letzte Prüfung im Papierkorb ab.
    @Test func entryReplacedJustBeforeTheEventIsCaughtByTheLastCheck() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let prefs = try fixture.file(fixture.userLibrary("Preferences/com.example.tool.plist"))
                let trash = LoggingTrash(log: log) {
                    try? FileManager.default.removeItem(atPath: cache)
                    _ = try? fixture.folder(cache)
                }
                let plan = RemovalPlan(app: nil, grants: [], autostartItems: [], files: [
                    candidate(cache, kind: .caches), candidate(prefs, kind: .preferences),
                ])
                let report = await executor(fixture, receipts: receipts, trash: trash).run(plan)
                #expect(trash.calls == [[cache, prefs]])
                #expect(report.entries.map(\.result) == [.failed("Nicht angefasst: Eintrag wurde ersetzt"), .done])
            }
        }
    }

    @Test func recreatedEntryIsDoneWithAWarning() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.tool"))
                let trash = LoggingTrash(log: log, recreated: [cache])
                let report = await executor(fixture, receipts: receipts, trash: trash)
                    .run(RemovalPlan(app: nil, grants: [], autostartItems: [], files: [candidate(cache, kind: .caches)]))
                #expect(report.entries.map(\.result) == [.doneWithWarning(RemovalExecutor.recreatedWarning)])
            }
        }
    }

    /// Aufräumen (`app == nil`) gibt keine Apple-Kennung frei.
    @Test func cleanupNeverTrashesAppleEntries() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let apple = try fixture.folder(fixture.userLibrary("Caches/com.apple.Keynote"))
                let report = await executor(fixture, receipts: receipts)
                    .run(RemovalPlan(app: nil, grants: [], autostartItems: [], files: [candidate(apple, kind: .caches)]))
                #expect(report.entries.map(\.result) == [.failed("Nicht angefasst: Apple-Eintrag")])
                #expect(!log.all.contains { $0.hasPrefix("trash") })
            }
        }
    }

    // MARK: Aufräumen gegen den aktuellen Stand (Review I1)

    /// Seit der Suche installiert (im Snapshot oder nur auf der Platte): Die Reste dieser App bleiben liegen.
    @Test func cleanupSkipsEntriesNowOwnedByAnInstalledApp() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let claw = try fixture.folder(fixture.userLibrary("Caches/ai.openclaw.mac.debug"))
                let molt = try fixture.folder(fixture.userLibrary("Caches/bot.molt.mac"))
                let team = try fixture.folder(fixture.userLibrary("Group Containers/TEAMB12345.com.example.shared"))
                let free = try fixture.folder(fixture.userLibrary("Caches/com.example.gone"))
                try fixture.app("Molt", bundleID: "bot.molt.mac")
                let openClaw = TestData.installedApp("OpenClaw", bundleID: "ai.openclaw.mac", path: "/Applications/OpenClaw.app")
                let teamApp = TestData.installedApp("Team", bundleID: "com.example.team", path: "/Applications/Team.app",
                                                    signing: SigningInfo(kind: .developerID, teamID: "TEAMB12345", isNotarized: true))
                let trash = LoggingTrash(log: log)
                let plan = cleanupPlan([
                    (candidate(claw, kind: .caches), OrphanClaim(identifiers: ["ai.openclaw.mac", "ai.openclaw.mac.debug"])),
                    (candidate(molt, kind: .caches), OrphanClaim(identifiers: ["bot.molt.mac"])),
                    (candidate(team, kind: .groupContainer), OrphanClaim(identifiers: ["com.example.shared"], team: "TEAMB12345")),
                    (candidate(free, kind: .caches), OrphanClaim(identifiers: ["com.example.gone"])),
                ])
                let report = await executor(fixture, receipts: receipts, trash: trash,
                                            current: TestData.appSnapshot([openClaw, teamApp])).run(plan)
                #expect(log.all == ["current", "permission", "trash 1"])
                #expect(trash.calls == [[free]])
                #expect(report.entries.map(\.result) == [
                    .skipped(OrphanRecheck.ownedReason(by: "OpenClaw")), .skipped(OrphanRecheck.ownedReason(by: "Molt")),
                    .skipped(OrphanRecheck.ownedReason(by: "Team")), .done,
                ])
            }
        }
    }

    /// Herstellerordner: übersprungen, sobald eine App des Herstellers oder mit dem Namen installiert ist.
    @Test func cleanupSkipsVendorFoldersOfANowInstalledVendor() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let folder = try fixture.folder(fixture.userLibrary("Application Support/OpenClaw"))
                let claim = OrphanClaim(identifiers: ["OpenClaw", "ai.openclaw.mac"],
                                        vendorFolder: OrphanClaim.VendorFolder(name: "OpenClaw", groupIdentifier: "ai.openclaw.mac"))
                let sibling = TestData.installedApp("Claw Studio", bundleID: "ai.openclaw.studio", path: "/Applications/Claw Studio.app")
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([sibling]))
                    .run(cleanupPlan([(candidate(folder, kind: .applicationSupport), claim)]))
                #expect(report.entries.map(\.result) == [.skipped(OrphanRecheck.ownedReason(by: "Claw Studio"))])
                #expect(log.all == ["current"], "ohne verbleibende Dateien keine Rückfrage beim Finder")
            }
        }
    }

    /// Ohne aktuellen Snapshot oder App-Inventar bleibt alles Geprüfte liegen; Autostart-Programm wieder da → übersprungen.
    @Test func cleanupWithoutCurrentStateTouchesNothing() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let cache = try fixture.folder(fixture.userLibrary("Caches/com.example.gone"))
                let item = TestData.item("com.example.gone.agent", programPresence: .missing)
                let plan = cleanupPlan([(candidate(cache, kind: .caches), OrphanClaim(identifiers: ["com.example.gone"]))],
                                       autostartItems: [item])
                let missing = await executor(fixture, receipts: receipts, current: nil).run(plan)
                #expect(missing.entries.map(\.result) == [.skipped(OrphanRecheck.unavailableReason), .skipped(OrphanRecheck.unavailableReason)])
                let noInventory = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([], baseline: TestData.allSources))
                    .run(plan)
                #expect(noInventory.entries.allSatisfy { if case .skipped = $0.result { true } else { false } })
                #expect(log.all == ["current", "current"])

                var revived = item
                revived.programPresence = .present
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([], items: [revived]))
                    .run(cleanupPlan([], autostartItems: [item]))
                #expect(report.entries.map(\.result) == [.skipped(OrphanRecheck.programPresentReason)])
            }
        }
    }

    // MARK: Reste einer App gegen den aktuellen Stand (#100)

    /// #100: Ein Gruppencontainer des Teams galt bei der Suche als exklusiv; seit dem Öffnen des Blatts ist eine weitere
    /// App desselben Teams installiert – der Container ist jetzt gemeinsam genutzt und bleibt liegen.
    @Test func groupContainerSharedWithANewTeamMateIsSkipped() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let full = try plan(fixture)
                let app = try #require(full.app)
                let team = try #require(app.signing.teamID)
                let container = try fixture.folder(fixture.userLibrary("Group Containers/\(team).com.example.shared"))
                let cache = full.files[1]
                let plan = RemovalPlan(app: app, grants: [], autostartItems: [],
                                       files: [candidate(container, kind: .groupContainer), cache])
                let mate = TestData.installedApp("Mate", bundleID: "com.example.mate", path: "/Applications/Mate.app",
                                                 signing: SigningInfo(kind: .developerID, teamID: team, isNotarized: true))
                let trash = LoggingTrash(log: log)
                let report = await executor(fixture, receipts: receipts, trash: trash, current: TestData.appSnapshot([app, mate]))
                    .run(plan)
                #expect(trash.calls == [[cache.path]], "der Gruppencontainer erreicht den Papierkorb nicht")
                #expect(report.entries.map(\.result) == [
                    .skipped(AppRemovalRecheck.sharedLeftoverReason("Team-ID auch bei: Mate")), .done,
                ])
                #expect(log.all == ["current", "permission", "trash 1"], "Abgleich vor der Finder-Rückfrage")
            }
        }
    }

    /// #100: Ein Rest, der bei der Suche per Präfix der Bundle-ID zur App gehörte, gehört jetzt einer länger benannten
    /// installierten App; eine seit der Suche hinzugekommene Installation derselben Bundle-ID macht Bundle-ID-Treffer
    /// gemeinsam – nur das App-Bundle selbst wird noch entfernt.
    @Test func leftoversNowOwnedOrSharedByAnotherAppAreSkipped() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let full = try plan(fixture)
                let app = try #require(full.app)
                let proData = try fixture.folder(fixture.userLibrary("Caches/com.example.tool.pro.data"))
                let plan = RemovalPlan(app: app, grants: [], autostartItems: [], files: full.files + [candidate(proData, kind: .caches)])
                let pro = TestData.installedApp("Tool Pro", bundleID: "com.example.tool.pro", path: "/Applications/Tool Pro.app")
                let copy = TestData.installedApp("Tool", bundleID: app.bundleID, path: "/Users/test/Applications/Tool.app")
                let trash = LoggingTrash(log: log)
                let report = await executor(fixture, receipts: receipts, trash: trash, current: TestData.appSnapshot([app, pro, copy]))
                    .run(plan)
                #expect(trash.calls == [[app.path]])
                #expect(report.entries.map(\.result) == [
                    .done, .skipped(AppRemovalRecheck.sharedLeftoverReason("Gehört evtl. auch zu: Tool")),
                    .skipped(AppRemovalRecheck.otherOwnerReason(app)),
                ])
            }
        }
    }

    /// #100: Ein bewusst gewählter unsicherer Rest läuft, solange sein Hinweis unverändert ist oder wegfällt; ein neuer
    /// Hinweis (weitere App des Herstellers) sperrt ihn.
    @Test func uncertainLeftoverRunsOnlyWhileItsNoteIsUnchanged() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let full = try plan(fixture)
                let app = try #require(full.app)
                let support = try fixture.folder(fixture.userLibrary("Application Support/Tool"))
                let logs = try fixture.folder(fixture.userLibrary("Logs/Tool"))
                let unnoted = LeftoverCandidate(path: support, kind: .applicationSupport, confidence: .uncertain,
                                                identity: FileIdentity.of(support))
                let noted = LeftoverCandidate(path: logs, kind: .logs, confidence: .uncertain, note: "Gehört evtl. auch zu: Mate",
                                              identity: FileIdentity.of(logs))
                let mate = TestData.installedApp("Mate", bundleID: "com.example.mate", path: "/Applications/Mate.app")
                let plan = RemovalPlan(app: app, grants: [], autostartItems: [], files: [unnoted, noted])

                let withMate = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([app, mate])).run(plan)
                #expect(withMate.entries.map(\.result) == [
                    .skipped(AppRemovalRecheck.sharedLeftoverReason("Gehört evtl. auch zu: Mate")), .done,
                ])
                let alone = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([app])).run(plan)
                #expect(alone.entries.map(\.result) == [.done, .done], "ein weggefallener Hinweis sperrt nicht")
            }
        }
    }

    /// #100: Liegt am Ort der App inzwischen eine andere App (andere Bundle-ID), passt der Plan nicht mehr – nichts wird
    /// angefasst, auch kein Finder angefragt.
    @Test func replacedAppBlocksTheWholePlan() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let plan = try plan(fixture)
                let app = try #require(plan.app)
                let other = TestData.installedApp("Tool", bundleID: "com.other.tool", path: app.path)
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([other])).run(plan)
                #expect(report == .skipping(plan, reason: AppRemovalRecheck.replacedReason(app, by: other)))
                #expect(log.all == ["current"])
            }
        }
    }

    /// #100: Dieselbe Bundle-ID am Ort, aber ein anderes Team (Austausch, Neusignierung): Der Plan passt nicht mehr. Ohne
    /// prüfbare Team-ID am Ort gilt die Zuordnung dagegen weiter, mit der App, wie sie jetzt dort liegt.
    @Test func resignedAppBlocksTheWholePlan() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let plan = try plan(fixture)
                let app = try #require(plan.app)
                let resigned = TestData.installedApp("Tool", bundleID: app.bundleID, path: app.path,
                                                     signing: SigningInfo(kind: .developerID, teamID: "OTHER12345", isNotarized: true))
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([resigned])).run(plan)
                #expect(report == .skipping(plan, reason: AppRemovalRecheck.resignedReason(app, team: "OTHER12345")))

                let unchecked = TestData.installedApp("Tool", bundleID: app.bundleID, path: app.path, signing: SigningInfo(kind: .unsigned))
                let lenient = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([unchecked])).run(plan)
                #expect(lenient.entries.allSatisfy { $0.result == .done })
            }
        }
    }

    /// #100: Ein Kandidat außerhalb der Reste-Orte lässt sich nicht neu zuordnen und bleibt liegen.
    @Test func leftoverOutsideTheSearchLocationsIsSkipped() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let full = try plan(fixture)
                let app = try #require(full.app)
                let stray = try fixture.folder(fixture.home + "/Documents/Tool")
                let plan = RemovalPlan(app: app, grants: [], autostartItems: [], files: [candidate(stray, kind: .applicationSupport)])
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([app])).run(plan)
                #expect(report.entries.map(\.result) == [.skipped(AppRemovalRecheck.unknownLocationReason)])
                #expect(log.all == ["current"])
            }
        }
    }

    /// #100: Ohne aktuellen Stand bzw. App-Inventar bleiben auch die Dateien einer App liegen (wie beim Aufräumen).
    @Test func uninstallWithoutCurrentStateTouchesNothing() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let full = try plan(fixture)
                let plan = RemovalPlan(app: full.app, grants: [], autostartItems: [], files: full.files)
                let missing = await executor(fixture, receipts: receipts, current: nil).run(plan)
                #expect(missing == .skipping(plan, reason: OrphanRecheck.unavailableReason))
                let noInventory = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([], baseline: TestData.allSources))
                    .run(plan)
                #expect(noInventory == .skipping(plan, reason: AppRemovalRecheck.missingInventoryReason))
                #expect(log.all == ["current", "current"], "keine Finder-Rückfrage, kein Papierkorb")
            }
        }
    }

    /// #97: Berechtigungen und Autostart-Einträge werden vor dem Eingriff gegen die aktuell installierten Apps geprüft –
    /// eine inzwischen aufgetauchte Installation derselben Bundle-ID sperrt, was beide träfe (Dateien: #100).
    @Test func newDuplicateInstallationSkipsSharedLinks() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let plan = try plan(fixture)
                let app = try #require(plan.app)
                let copy = TestData.installedApp("Tool", bundleID: app.bundleID, path: "/Users/test/Applications/Tool.app")
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([app, copy])).run(plan)
                let reason = AppRemovalRecheck.sharedReason(with: [copy])
                #expect(report.entries.map(\.result) == [
                    .skipped(reason), .skipped(reason), .done,
                    .skipped(AppRemovalRecheck.sharedLeftoverReason("Gehört evtl. auch zu: Tool")),
                ])
                #expect(!log.all.contains { $0.hasPrefix("reset") || $0.hasPrefix("remove") })
            }
        }
    }

    /// Bewusst gewählte gemeinsame Einträge (`acknowledgedSharedIDs`) laufen, solange keine weitere Installation hinzukam.
    @Test func acknowledgedSharedLinksRun() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let full = try plan(fixture)
                let app = try #require(full.app)
                let copy = TestData.installedApp("Tool", bundleID: app.bundleID, path: "/Users/test/Applications/Tool.app")
                let plan = RemovalPlan(app: app, grants: full.grants, autostartItems: full.autostartItems, files: [],
                                       acknowledgedSharedIDs: Set(full.grants.map(\.id) + full.autostartItems.map(\.id)),
                                       knownOtherInstallations: [copy.path])
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([app, copy])).run(plan)
                #expect(report.entries.allSatisfy { $0.result == .done })
            }
        }
    }

    /// Review: Eine Bestätigung gilt nur für die bei der Auswahl bekannten Installationen – eine dritte sperrt wieder.
    @Test func acknowledgedSharedLinksAreSkippedWhenAnotherInstallationAppeared() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let full = try plan(fixture)
                let app = try #require(full.app)
                let copy = TestData.installedApp("Tool", bundleID: app.bundleID, path: "/Users/test/Applications/Tool.app")
                let third = TestData.installedApp("Tool", bundleID: app.bundleID, path: "/Users/test/Downloads/Tool.app")
                let plan = RemovalPlan(app: app, grants: full.grants, autostartItems: full.autostartItems, files: [],
                                       acknowledgedSharedIDs: Set(full.grants.map(\.id) + full.autostartItems.map(\.id)),
                                       knownOtherInstallations: [copy.path])
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([app, copy, third]))
                    .run(plan)
                let reason = AppRemovalRecheck.sharedReason(with: [third])
                #expect(report.entries.map(\.result) == [.skipped(reason), .skipped(reason)])
                #expect(log.all == ["current"])
            }
        }
    }

    /// Liegt das Programm eines Eintrags inzwischen in einer anderen installierten App, bleibt er unberührt.
    @Test func linkOfAnotherInstallationIsSkipped() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let full = try plan(fixture)
                let app = try #require(full.app)
                let other = TestData.installedApp("Tool", bundleID: app.bundleID, path: "/Applications/Tool.app")
                var item = TestData.item("com.example.tool.helper", owner: app.identity)
                item.program = other.path + "/Contents/MacOS/helper"
                let plan = RemovalPlan(app: app, grants: [], autostartItems: [item], files: [],
                                       acknowledgedSharedIDs: [item.id], knownOtherInstallations: [other.path])
                let report = await executor(fixture, receipts: receipts, current: TestData.appSnapshot([app, other])).run(plan)
                #expect(report.entries.map(\.result) == [.skipped(AppRemovalRecheck.otherOwnerReason(app))])
                #expect(log.all == ["current"])
            }
        }
    }

    /// Ohne aktuellen Stand bleiben Berechtigungen, Autostart-Einträge und Dateien unberührt (#97, #100).
    @Test func missingCurrentSnapshotSkipsEverything() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let plan = try plan(fixture)
                let report = await executor(fixture, receipts: receipts, current: nil).run(plan)
                #expect(report == .skipping(plan, reason: OrphanRecheck.unavailableReason))
                #expect(log.all == ["current"])
            }
        }
    }

    @Test func singleFailuresDoNotStopTheRest() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let plan = try plan(fixture)
                let trash = LoggingTrash(log: log, remaining: [plan.files[1].path: "Abgebrochen (z. B. Passwortabfrage)"])
                let report = await executor(fixture, receipts: receipts, trash: trash, failingResets: ["kTCCServiceCamera"]).run(plan)
                #expect(report.entries.map(\.result) == [
                    .failed("Befehl fehlgeschlagen"), .done, .done, .failed("Abgebrochen (z. B. Passwortabfrage)"),
                ])
            }
        }
    }

    /// Startet die App zwischen Prüfung und Papierkorb, bleiben die Dateien liegen.
    @Test func appStartedMeanwhileSkipsTheFiles() async throws {
        try await LibraryFixture.with { fixture in
            try await withReceipts { receipts in
                let report = await executor(fixture, receipts: receipts, running: [false, true]).run(try plan(fixture))
                #expect(report.entries.prefix(2).allSatisfy { $0.result == .done })
                #expect(report.entries.suffix(2).allSatisfy { $0.result == .skipped("Tool läuft noch – bitte zuerst beenden.") })
                #expect(!log.all.contains { $0.hasPrefix("trash") })
            }
        }
    }
}

@Suite struct RemovalPlanningTests {
    @Test func planTakesOnlySelectedAndAllowedEntries() {
        let app = TestData.installedApp()
        let grant = TestData.grant(client: app.identity)
        let otherGrant = TestData.grant(client: TestData.app("com.example.other"))
        let item = TestData.item("us.zoom.agent", owner: app.identity)
        let btm = TestData.item("us.zoom.login", kind: .loginItem, source: .btm, owner: app.identity)
        let snapshot = TestData.appSnapshot([app], grants: [grant, otherGrant], items: [item, btm])
        let candidates = [
            LeftoverCandidate(path: app.path, kind: .appBundle, confidence: .safe),
            LeftoverCandidate(path: "/Users/test/Library/Caches/us.zoom.xos", kind: .caches, confidence: .safe, size: .bytes(3)),
            LeftoverCandidate(path: "/Users/test/Library/Application Support/Zoom", kind: .applicationSupport, confidence: .uncertain),
        ]
        let scan = LeftoverScanResult(candidates: candidates, unreadableLocations: ["/Users/test/Library/Containers"])
        let plan = RemovalPlanning.plan(for: app, leftovers: scan, snapshot: snapshot,
                                        selection: [app.path, candidates[1].path, grant.id, item.id, btm.id, otherGrant.id])
        #expect(plan.app == app)
        #expect(plan.grants == [grant])
        #expect(plan.autostartItems == [item], "BTM-Einträge verwalten die Systemeinstellungen")
        #expect(plan.files == [candidates[0], candidates[1]], "unverändert aus der Suche (Identität)")
        #expect(plan.unreadableLocations == ["/Users/test/Library/Containers"])
        #expect(AppLinks.of(app, in: snapshot) == AppLinks(grants: [grant], autostartItems: [item, btm]))
    }

    @Test func linksMatchByBundleIDOrPath() {
        let app = TestData.installedApp("Tool", bundleID: nil, path: "/Applications/Tool.app")
        let byPath = TestData.grant(client: AppIdentity(bundleID: nil, path: "/Applications/Tool.app", displayName: "Tool",
                                                        signing: SigningInfo(kind: .adHoc), presence: .present))
        let other = TestData.grant(client: TestData.app("com.example.tool"))
        let snapshot = TestData.appSnapshot([app], grants: [byPath, other])
        #expect(AppLinks.of(app, in: snapshot).grants == [byPath])
    }

    @Test func cleanupPlanTakesSelectedOrphansAndAutostartItems() {
        let orphan = LeftoverCandidate(path: "/Users/test/Library/Caches/ai.openclaw.mac", kind: .caches, confidence: .safe)
        let other = LeftoverCandidate(path: "/Users/test/Library/Caches/bot.molt.mac", kind: .caches, confidence: .uncertain)
        let item = TestData.item("ai.openclaw.gateway", programPresence: .missing)
        let result = OrphanScanResult(
            groups: [OrphanGroup(identifier: "ai.openclaw.mac", candidates: [orphan]),
                     OrphanGroup(identifier: "bot.molt.mac", candidates: [other])],
            autostartItems: [item], grants: [TestData.grant()], unreadableLocations: ["/Library/Caches"]
        )
        let plan = RemovalPlanning.plan(cleanup: result, selection: [orphan.path, item.id, TestData.grant().id])
        #expect(plan.app == nil)
        #expect(plan.grants.isEmpty, "verwaiste Berechtigungen nur als Hinweis")
        #expect(plan.autostartItems == [item])
        #expect(plan.files == [orphan])
        #expect(plan.unreadableLocations == ["/Library/Caches"])
        #expect(plan.orphanClaims.isEmpty)
    }

    @Test func cleanupPlanCarriesTheClaimsOfSelectedFiles() {
        let orphan = LeftoverCandidate(path: "/Users/test/Library/Caches/ai.openclaw.mac", kind: .caches, confidence: .safe)
        let other = LeftoverCandidate(path: "/Users/test/Library/Caches/ai.openclaw.mac.debug", kind: .caches, confidence: .safe)
        let claims = [orphan.path: OrphanClaim(identifiers: ["ai.openclaw.mac"]),
                      other.path: OrphanClaim(identifiers: ["ai.openclaw.mac", "ai.openclaw.mac.debug"])]
        let result = OrphanScanResult(groups: [OrphanGroup(identifier: "ai.openclaw.mac", candidates: [orphan, other], claims: claims)],
                                      autostartItems: [], grants: [])
        let plan = RemovalPlanning.plan(cleanup: result, selection: [orphan.path])
        #expect(plan.orphanClaims == [orphan.path: OrphanClaim(identifiers: ["ai.openclaw.mac"])])
    }

    @Test func routes() {
        #expect(RemovalRoute.route(for: TestData.installedApp(), ownBundleID: "de.cstrube.Grantry", ownPath: "/x") == .removable)
        #expect(RemovalRoute.route(for: TestData.installedApp(origin: .homebrew(cask: "zoom")), ownBundleID: "de.cstrube.Grantry",
                                   ownPath: "/x") == .homebrew(command: "brew uninstall --cask zoom"))
        #expect(RemovalRoute.route(for: TestData.installedApp(origin: .homebrew(cask: "a b;c'd")), ownBundleID: "x", ownPath: "/x")
                == .homebrew(command: #"brew uninstall --cask 'a b;c'\''d'"#))
        #expect(RemovalRoute.route(for: TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry", path: "/Applications/Grantry.app"),
                                   ownBundleID: "de.cstrube.Grantry", ownPath: "/Applications/Grantry.app") == .grantryItself)
        // Eine zweite Kopie mit derselben Bundle-ID ist nicht die laufende Grantry (#131).
        #expect(RemovalRoute.route(for: TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry", path: "/Users/test/Applications/Grantry.app"),
                                   ownBundleID: "de.cstrube.Grantry", ownPath: "/Applications/Grantry.app") == .otherGrantryCopy)
        #expect(RemovalRoute.route(for: TestData.installedApp("Kopie", bundleID: nil, path: "/Applications/Kopie.app"),
                                   ownBundleID: "de.cstrube.Grantry", ownPath: "/Applications/Kopie.app") == .grantryItself)
        #expect(RemovalRoute.removable.reason == nil)
        #expect(RemovalRoute.otherGrantryCopy.reason != nil)
        #expect(RemovalRoute.homebrew(command: "brew uninstall --cask zoom").reason
                == "Über Homebrew installiert – bitte „brew uninstall --cask zoom“ im Terminal ausführen.")
    }
}

@Suite struct RunningApplicationsTests {
    @Test func matchesByBundleIDOrBundlePath() {
        let app = TestData.installedApp()
        #expect(WorkspaceRunningApplications.matches(bundleID: "US.ZOOM.XOS", bundleURL: nil, app: app))
        #expect(WorkspaceRunningApplications.matches(bundleID: nil, bundleURL: URL(fileURLWithPath: app.path), app: app))
        #expect(!WorkspaceRunningApplications.matches(bundleID: "com.example.other", bundleURL: URL(fileURLWithPath: "/Applications/Other.app"), app: app))
        #expect(!WorkspaceRunningApplications.matches(bundleID: nil, bundleURL: nil, app: TestData.installedApp(bundleID: nil)))
    }
}
