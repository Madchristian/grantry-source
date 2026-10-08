import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Protokolliert die Aufrufe in Reihenfolge und liefert `outcome`; Entfernungen melden je Datei „erledigt“.
private final class RecordingPerformer: ActionPerforming {
    let outcome: ActionOutcome
    private let log = Mutex<[String]>([])

    init(outcome: ActionOutcome = .done) {
        self.outcome = outcome
    }

    var calls: [String] { log.withLock { $0 } }

    private func record(_ call: String) { log.withLock { $0.append(call) } }

    func reset(_ grant: PermissionGrant) async -> ActionOutcome { record("reset \(grant.id)"); return outcome }
    func resetService(_ reset: ServiceReset) async -> ActionOutcome { outcome }
    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async -> ActionOutcome { outcome }
    func remove(_ item: AutostartItem) async -> ActionOutcome { record("remove \(item.id)"); return outcome }
    func restore(receiptID: UUID) async -> ActionOutcome { outcome }
    func removeServer(_ entry: MCPServerEntry) async -> ActionOutcome { outcome }
    func setServerEnabled(_ entry: MCPServerEntry, _ enabled: Bool) async -> ActionOutcome { outcome }
    func restoreAgentChange(_ change: AgentConfigChange) async -> ActionOutcome { outcome }
    func perform(_ action: SecurityAction) async -> ActionOutcome { outcome }
    func performRemoval(
        _ plan: RemovalPlan, onExecuted: @escaping @Sendable (RemovalReport) async -> Void
    ) async -> RemovalReport {
        record("removal \(plan.id)")
        let report = RemovalReport(entries: plan.files.map { .init(subject: .file($0), result: .done) })
        await onExecuted(report)
        return report
    }
    func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationResult {
        Issue.record("Prozess beenden nicht erwartet")
        return ProcessTerminationResult(request: request, force: force, outcome: .failed("nicht erwartet"), report: ProcessTerminationReport())
    }
    func drain() async {}
}

@Suite("Aufräumen aus einer Beobachtung")
struct ObservationCleanupTests {
    private let signing = SigningInfo(kind: .developerID, teamID: "VDXQ22DGB9", isNotarized: true)
    private let later = TestData.date.addingTimeInterval(600)

    private var cursor: InstalledApp { TestData.installedApp("Cursor", bundleID: "com.todesktop.cursor", signing: signing) }

    private var cursorGrant: PermissionGrant {
        TestData.grant("kTCCServiceAccessibility", client: AppIdentity(
            bundleID: "com.todesktop.cursor", path: cursor.path, displayName: "Cursor", signing: signing, presence: .present
        ), scope: .system)
    }

    private var foreignGrant: PermissionGrant {
        TestData.grant("kTCCServiceScreenCapture", client: TestData.app("us.zoom.xos"), scope: .system)
    }

    private var cursorAgent: AutostartItem { TestData.item("com.todesktop.cursor.updater") }

    private func balance(final: Snapshot) -> ObservationBalance {
        ObservationBalance(baseline: TestData.appSnapshot([]), final: final)
    }

    private var final: Snapshot {
        TestData.appSnapshot([cursor], grants: [cursorGrant, foreignGrant], items: [cursorAgent], at: later)
    }

    private func offer(current: Snapshot) -> ObservationCleanupOffer {
        ObservationCleanupOffer(
            balance: balance(final: final),
            attribution: ObservationAttribution(observationName: "Cursor", newApps: [cursor]),
            current: current
        )
    }

    @Test func offersStillPresentEntriesPreselectingOnlyLikelyOnes() {
        let offer = offer(current: final)
        #expect(Set(offer.candidates.map(\.id)) == [cursor.id, cursorGrant.id, foreignGrant.id, cursorAgent.id])
        #expect(offer.initialSelection.selected == [cursor.id, cursorGrant.id, cursorAgent.id])
        #expect(offer.goneCount == 0)
    }

    /// Nachträgliches Aufräumen prüft gegen den aktuellen Stand: Entferntes und Ausgetauschtes wird nicht angeboten.
    @Test func laterCleanupChecksAgainstTheCurrentSnapshot() {
        var replacedAgent = cursorAgent
        replacedAgent.program = "/tmp/other"
        var otherTeam = cursor
        otherTeam.signing = SigningInfo(kind: .developerID, teamID: "OTHERTEAM1")
        let current = TestData.appSnapshot([otherTeam], grants: [cursorGrant], items: [replacedAgent], at: later)
        let offer = offer(current: current)
        #expect(offer.candidates.map(\.id) == [cursorGrant.id])
        #expect(offer.goneCount == 3)
    }

    /// Gleiches Label, gleiche Domain, gleicher Interpreter – aber eine andere Plist: ein anderer Eintrag, nicht der
    /// beobachtete (#156). Erst Pfad und Inhaltsfingerabdruck machen ihn zu demselben.
    @Test func autostartItemWithAnotherPlistOrChangedContentIsNotOffered() {
        var recorded = cursorAgent
        recorded.program = "/opt/homebrew/bin/python3"
        recorded.plistPath = "/Users/test/Library/LaunchAgents/com.todesktop.cursor.updater.plist"
        recorded.plistFingerprint = FileFingerprint(modified: TestData.date, fileNumber: 41, statusChanged: TestData.date, size: 300)
        let balance = balance(final: TestData.appSnapshot([], grants: [], items: [recorded], at: later))
        func offer(_ current: AutostartItem) -> ObservationCleanupOffer {
            ObservationCleanupOffer(
                balance: balance, attribution: ObservationAttribution(observationName: "Cursor", newApps: []),
                current: TestData.appSnapshot([], grants: [], items: [current], at: later)
            )
        }
        var otherPlist = recorded
        otherPlist.plistPath = "/Users/test/Library/LaunchAgents/com.todesktop.cursor.updater.plist.bak-restored"
        #expect(offer(otherPlist).candidates.isEmpty)
        #expect(offer(otherPlist).goneCount == 1)

        var rewritten = recorded
        rewritten.plistFingerprint = FileFingerprint(modified: later, fileNumber: 41, statusChanged: later, size: 420)
        #expect(offer(rewritten).candidates.isEmpty)

        #expect(offer(recorded).candidates.map(\.id) == [recorded.id])
        // Ältere Snapshots ohne Fingerabdruck: Pfad und Programm genügen.
        var unknown = recorded
        unknown.plistFingerprint = nil
        #expect(offer(unknown).candidates.map(\.id) == [recorded.id])
    }

    @Test func readOnlyEntriesAreShownButNotPreselected() {
        var missingClient = cursorGrant
        missingClient.client.presence = .missing
        let current = TestData.appSnapshot([cursor], grants: [missingClient, foreignGrant], items: [cursorAgent], at: later)
        let candidate = offer(current: current).candidates.first { $0.id == cursorGrant.id }
        #expect(candidate?.unavailableReason != nil)
        #expect(candidate?.isPreselected == false)
    }

    @Test func planPutsLinkedEntriesIntoTheAppRemovalAndTheRestIntoSingleActions() throws {
        let offer = offer(current: final)
        var selection = offer.initialSelection
        selection.set(foreignGrant.id, selected: true)
        let leftovers = LeftoverScanResult(candidates: [
            LeftoverCandidate(path: cursor.path, kind: .appBundle, confidence: .safe),
            LeftoverCandidate(path: "/Users/test/Library/Caches/com.todesktop.cursor", kind: .caches, confidence: .safe),
            LeftoverCandidate(path: "/Users/test/Library/Application Support/Cursor", kind: .applicationSupport,
                              confidence: .uncertain),
        ])
        let id = UUID()
        let plan = ObservationCleanupPlanning.plan(
            observationID: id, offer: offer, selection: selection, leftovers: [cursor.id: leftovers], snapshot: final
        )
        let removal = try #require(plan.appRemovals.first)
        #expect(removal.app == cursor)
        #expect(removal.grants == [cursorGrant])
        // Nur das App-Bundle: Reste können vor der Beobachtung bestanden haben und gehen über das Entfernen-Blatt.
        #expect(removal.files.map(\.path) == [cursor.path])
        #expect(plan.grants == [foreignGrant])
        // Der Agent hat keinen Eigentümer und läuft deshalb einzeln.
        #expect(plan.autostartItems == [cursorAgent])
        #expect(plan.id == "observation|\(id.uuidString)")
    }

    @Test func appsWithoutLeftoverScanAreLeftOut() {
        let offer = offer(current: final)
        let plan = ObservationCleanupPlanning.plan(
            observationID: UUID(), offer: offer, selection: offer.initialSelection, leftovers: [:], snapshot: final
        )
        #expect(plan.appRemovals.isEmpty)
        #expect(plan.grants == [cursorGrant])
    }

    @Test func executorRunsGrantsThenAutostartThenAppsAndReportsEach() async {
        let performer = RecordingPerformer(outcome: .doneButUnverified("Überprüfung ausstehend"))
        let removal = RemovalPlan(app: cursor, grants: [], autostartItems: [], files: [
            LeftoverCandidate(path: cursor.path, kind: .appBundle, confidence: .safe),
        ])
        let plan = ObservationCleanupPlan(
            observationID: UUID(), grants: [foreignGrant], autostartItems: [cursorAgent], appRemovals: [removal]
        )
        let executed = Mutex(0)
        let report = await ObservationCleanupExecutor(performer: performer).run(plan) { _ in executed.withLock { $0 += 1 } }
        #expect(performer.calls == ["reset \(foreignGrant.id)", "remove \(cursorAgent.id)", "removal \(cursor.id)"])
        #expect(report.entries.map(\.result) == [
            .doneWithWarning("Überprüfung ausstehend"), .doneWithWarning("Überprüfung ausstehend"), .done,
        ])
        #expect(executed.withLock { $0 } == 1)
    }

    /// Jeder Eintrag geht sofort an `onEntry` – Erledigtes bleibt bekannt, auch wenn das Warten verworfen wird.
    @Test func executorReportsEntriesAsTheyHappen() async {
        let performer = RecordingPerformer()
        let plan = ObservationCleanupPlan(
            observationID: UUID(), grants: [foreignGrant], autostartItems: [cursorAgent], appRemovals: []
        )
        let seen = Mutex<[RemovalReport.Entry]>([])
        let report = await ObservationCleanupExecutor(performer: performer)
            .run(plan, onEntry: { entry in seen.withLock { $0.append(entry) } }) { _ in }
        #expect(seen.withLock { $0 } == report.entries)
    }

    @Test func cancelledExecutorStartsNoFurtherStep() async {
        let performer = RecordingPerformer()
        let plan = ObservationCleanupPlan(
            observationID: UUID(), grants: [foreignGrant], autostartItems: [cursorAgent], appRemovals: []
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ObservationCleanupExecutor(performer: performer).run(plan) { _ in }
        }
        let report = await task.value
        #expect(performer.calls.isEmpty)
        #expect(report.entries.allSatisfy { $0.result == .skipped(RemovalExecutor.abortedReason) })
    }

    @MainActor
    @Test func runnerReturnsTheReportAndPresentsIt() async {
        let runner = ActionRunner(helperActivity: HelperActivityLock(), coordinator: RecordingPerformer())
        let plan = ObservationCleanupPlan(observationID: UUID(), grants: [foreignGrant], autostartItems: [], appRemovals: [])
        let report = await runner.performObservationCleanup(plan, context: .observations)
        #expect(report?.entries.map(\.result) == [.done])
        #expect(runner.result(in: .observations) == .removal(report!))
    }

    @Test func confirmationNamesEveryEntry() {
        let removal = RemovalPlan(app: cursor, grants: [cursorGrant], autostartItems: [], files: [
            LeftoverCandidate(path: cursor.path, kind: .appBundle, confidence: .safe, size: .bytes(1_000)),
            LeftoverCandidate(path: "/Users/test/Library/Caches/x", kind: .caches, confidence: .safe, size: .bytes(1_000)),
        ])
        let plan = ObservationCleanupPlan(
            observationID: UUID(), grants: [foreignGrant], autostartItems: [cursorAgent], appRemovals: [removal]
        )
        let confirmation = ActionConfirmation.observationCleanup(plan, name: "Cursor", home: "/Users/test")
        let lines = confirmation.message?.split(separator: "\n").map(String.init) ?? []
        #expect(confirmation.title == "Aus „Cursor“ entfernen?")
        #expect(lines.count == 5)
        #expect(lines[0].hasPrefix("Berechtigung zurücksetzen: Bildschirmaufnahme"))
        #expect(lines[1].hasPrefix("Berechtigung zurücksetzen: Bedienungshilfen"))
        #expect(lines[2] == "Autostart-Eintrag entfernen (mit Sicherung): „com.todesktop.cursor.updater“")
        #expect(lines[3].hasPrefix("In den Papierkorb: „Cursor“ ("))
        // Jede Datei einzeln, nicht als „und N Reste“.
        #expect(lines[4].hasPrefix("In den Papierkorb: ~/Library/Caches/x ("))
        #expect(confirmation.note?.contains(ObservationTexts.leftoversNote) == true)
        #expect(confirmation.isDestructive)
    }

    /// `tccutil` setzt Automation nur für **alle** Ziele der App zurück – auch Ziele von vor der Beobachtung. Die
    /// Sammelbestätigung nennt das Ziel und warnt wie der Einzelreset (#156).
    @Test func confirmationWarnsThatAutomationResetHitsAllTargets() {
        var automation = TestData.grant(PermissionCatalog.automationServiceID, client: TestData.app("us.zoom.xos"))
        automation.target = "com.apple.finder"
        let plan = ObservationCleanupPlan(observationID: UUID(), grants: [automation], autostartItems: [], appRemovals: [])
        let confirmation = ActionConfirmation.observationCleanup(plan, name: "Zoom", home: "/Users/test")
        #expect(confirmation.message == "Berechtigung zurücksetzen: Automation (Ziel: com.apple.finder)-Berechtigung von us.zoom.xos")
        #expect(confirmation.note == ActionConfirmation.automationResetNote(clientName: "us.zoom.xos"))
        #expect(confirmation.note?.contains("alle Automation-Freigaben") == true)
    }

    @Test func cleanupRecordKeepsTitlesAndReasons() {
        let report = RemovalReport(entries: [
            .init(subject: .autostartItem(cursorAgent), result: .done),
            .init(subject: .grant(foreignGrant), result: .failed("tccutil fehlgeschlagen")),
        ])
        let record = ObservationCleanupRecord(report, performedAt: later)
        #expect(record.entries.map(\.title).first == "„com.todesktop.cursor.updater“")
        #expect(record.entries.map(\.reason) == [nil, "tccutil fehlgeschlagen"])
        #expect(record.doneCount == 1)
    }
}
