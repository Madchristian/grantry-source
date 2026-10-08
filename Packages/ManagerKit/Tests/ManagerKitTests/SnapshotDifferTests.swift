import Testing
import Foundation
@testable import ManagerKit

@Suite struct SnapshotDifferTests {
    let differ = SnapshotDiffer()
    let later = TestData.date.addingTimeInterval(60)

    @Test func baselineProducesNoEvents() {
        let current = TestData.snapshot(grants: [TestData.grant()])
        #expect(differ.diff(from: nil, to: current).isEmpty)
    }

    @Test func detectsAddedGrant() {
        let previous = TestData.snapshot()
        let current = TestData.snapshot(grants: [TestData.grant()], at: later)
        let events = differ.diff(from: previous, to: current)
        #expect(events == [ChangeEvent(kind: .added, before: nil, after: .grant(TestData.grant()), detectedAt: later)])
    }

    @Test func detectsRemovedItem() {
        let item = TestData.item()
        let events = differ.diff(from: TestData.snapshot(items: [item]), to: TestData.snapshot(at: later))
        #expect(events.map(\.kind) == [.removed])
        #expect(events.first?.subject == .autostartItem(item))
    }

    @Test func detectsModifiedGrant() {
        let allowed = TestData.grant(authValue: .allowed)
        let denied = TestData.grant(authValue: .denied)
        let events = differ.diff(from: TestData.snapshot(grants: [allowed]), to: TestData.snapshot(grants: [denied], at: later))
        #expect(events == [ChangeEvent(kind: .modified, before: .grant(allowed), after: .grant(denied), detectedAt: later)])
    }

    @Test func ignoresInsignificantChanges() {
        let grant = TestData.grant()
        var touched = grant
        touched.lastModified = later
        #expect(differ.diff(from: TestData.snapshot(grants: [grant]), to: TestData.snapshot(grants: [touched], at: later)).isEmpty)
    }

    @Test func failedSourceDoesNotProduceRemovals() {
        let btmItem = TestData.item("com.docker.docker", kind: .loginItem, source: .btm)
        let launchdItem = TestData.item("com.example.agent", source: .launchd)
        let previous = TestData.snapshot(items: [btmItem, launchdItem])
        let current = TestData.snapshot(errors: [SourceError(source: .btm, message: "helper offline")], at: later)
        let events = differ.diff(from: previous, to: current)
        #expect(events.map(\.subject) == [.autostartItem(launchdItem)])
        #expect(events.map(\.kind) == [.removed])
    }

    @Test func eventsAreSortedDeterministically() {
        let a = TestData.grant("kTCCServiceCamera")
        let b = TestData.grant("kTCCServiceMicrophone")
        let events = differ.diff(from: TestData.snapshot(), to: TestData.snapshot(grants: [b, a], at: later))
        #expect(events.map(\.subject) == [.grant(a), .grant(b)])
    }

    @Test func failedTCCSourceDoesNotProduceGrantRemovals() {
        let previous = TestData.snapshot(grants: [TestData.grant()])
        let current = TestData.snapshot(errors: [SourceError(source: .tccUser, message: "kein Vollzugriff")], at: later)
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    @Test func failedUserTCCSourceStillReportsSystemGrantRemovals() {
        let userGrant = TestData.grant(scope: .user)
        let systemGrant = TestData.grant(scope: .system)
        let previous = TestData.snapshot(grants: [userGrant, systemGrant])
        let current = TestData.snapshot(errors: [SourceError(source: .tccUser, message: "kein Zugriff")], at: later)
        #expect(differ.diff(from: previous, to: current) == [
            ChangeEvent(kind: .removed, before: .grant(systemGrant), after: nil, detectedAt: later),
        ])
    }

    @Test func detectsModifiedAutostartItem() {
        let enabled = TestData.item(isEnabled: true)
        let disabled = TestData.item(isEnabled: false)
        let events = differ.diff(from: TestData.snapshot(items: [enabled]), to: TestData.snapshot(items: [disabled], at: later))
        #expect(events == [ChangeEvent(kind: .modified, before: .autostartItem(enabled), after: .autostartItem(disabled), detectedAt: later)])
    }

    @Test func grantsPrecedeAutostartItems() {
        let grant = TestData.grant()
        let item = TestData.item("a.first.label")
        let events = differ.diff(from: TestData.snapshot(), to: TestData.snapshot(grants: [grant], items: [item], at: later))
        #expect(events.map(\.subject) == [.grant(grant), .autostartItem(item)])
    }

    @Test func duplicateIDsDoNotTrapAndFirstWins() {
        let first = TestData.grant(authValue: .allowed)
        let second = TestData.grant(authValue: .denied)
        let events = differ.diff(from: TestData.snapshot(), to: TestData.snapshot(grants: [first, second], at: later))
        #expect(events == [ChangeEvent(kind: .added, before: nil, after: .grant(first), detectedAt: later)])
    }

    @Test func firstSuccessfulDeliveryOfSourceIsBaselineWithoutAdditions() {
        let agent = TestData.item("com.example.agent", source: .launchd)
        let docker = TestData.item("com.docker.docker", kind: .loginItem, source: .btm)
        let zoom = TestData.item("us.zoom.xos", kind: .loginItem, source: .btm)
        let dropbox = TestData.item("com.dropbox.client", kind: .loginItem, source: .btm)
        let btmFailure = SourceError(source: .btm, message: "helper offline")

        let s1 = TestData.snapshot(items: [agent], errors: [btmFailure], baseline: [.launchd])
        let s2 = TestData.snapshot(items: [agent, docker, zoom], baseline: [.launchd, .btm], at: later)
        #expect(differ.diff(from: s1, to: s2).isEmpty)

        let s3 = TestData.snapshot(items: [agent, docker, zoom, dropbox], baseline: [.launchd, .btm], at: later.addingTimeInterval(60))
        #expect(differ.diff(from: s2, to: s3) == [
            ChangeEvent(kind: .added, before: nil, after: .autostartItem(dropbox), detectedAt: later.addingTimeInterval(60)),
        ])
    }

    @Test func removalsAndModificationsIgnoreBaseline() {
        let enabled = TestData.item(isEnabled: true)
        let disabled = TestData.item(isEnabled: false)
        let grant = TestData.grant()
        let previous = TestData.snapshot(grants: [grant], items: [enabled], baseline: [])
        let current = TestData.snapshot(items: [disabled], baseline: [], at: later)
        #expect(differ.diff(from: previous, to: current).map(\.kind) == [.removed, .modified])
    }

    @Test func securityChecksBaselineThenModified() {
        var first = TestData.snapshot(baseline: [])
        first.securityChecks = [TestData.securityCheck(TestData.firewallOn, state: .good)]
        var baselined = first
        baselined.baselineSources = [.securityPosture]
        #expect(differ.diff(from: TestData.snapshot(baseline: []), to: baselined).isEmpty)  // erster Lauf = Baseline
        var second = baselined
        second.securityChecks = [TestData.securityCheck(TestData.stealthOff, state: .warning)]
        let events = differ.diff(from: baselined, to: second)
        #expect(events.map(\.kind) == [.modified])
        #expect(events.first?.subject.recordID == "firewall")
    }

    @Test func agingWithoutStateChangeIsNoEvent() {
        var a = TestData.snapshot()
        a.securityChecks = [TestData.securityCheck(.xprotect(version: "1", installedAt: TestData.date), state: .good)]
        var b = a
        b.securityChecks = [TestData.securityCheck(.xprotect(version: "1", installedAt: TestData.date + 86_400), state: .good)]
        b.takenAt = TestData.date + 86_400
        #expect(differ.diff(from: a, to: b).isEmpty)
    }

    /// Bisher nie lesbare Prüfung (keine Ampel, keine Werte) wird erstmals lesbar: Baseline, kein „… geändert.“ –
    /// auch nicht, wenn der erste Wert kritisch ist (Ampel und Kachel zeigen ihn ohnehin).
    @Test(arguments: [SecurityState.good, .critical])
    func firstReadableValueOfANeverReadCheckIsNoEvent(_ state: SecurityState) {
        var previous = TestData.snapshot()
        previous.securityChecks = [SecurityCheck.failed(.firewall, detail: "nicht lesbar")]
        var current = previous
        current.securityChecks = [TestData.securityCheck(TestData.firewallOff, state: state)]
        current.takenAt = TestData.date + 60
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    @Test func failureWithCarriedValuesIsNoEvent() {
        let good = TestData.securityCheck(TestData.firewallOn, state: .good)
        var previous = TestData.snapshot()
        previous.securityChecks = [good]
        var current = previous
        current.securityChecks = [SecurityCheck(
            kind: .firewall, state: .unknown, facts: TestData.firewallOn, detail: "nicht lesbar", lastKnownState: .good
        )]
        current.takenAt = TestData.date + 60
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    @Test func firstAppScanIsBaseline() {
        let previous = TestData.snapshot()  // Baseline ohne .apps
        let current = TestData.appSnapshot([TestData.installedApp()], at: later)
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    @Test func detectsInstalledUpdatedAndRemovedApps() {
        let zoom = TestData.installedApp()
        let previous = TestData.appSnapshot([zoom])
        let updated = TestData.installedApp(version: "6.1")
        let added = TestData.installedApp("Tool", bundleID: "com.example.tool")
        let events = differ.diff(from: previous, to: TestData.appSnapshot([updated, added], at: later))
        #expect(events.map(\.kind) == [.added, .modified])
        #expect(events.map(\.subject) == [.installedApp(added), .installedApp(updated)])
        #expect(differ.diff(from: previous, to: TestData.appSnapshot([], at: later)).map(\.kind) == [.removed])
    }

    @Test func unreadableSigningProducesNoAppEvent() {
        let previous = TestData.appSnapshot([TestData.installedApp()])
        let current = TestData.appSnapshot([TestData.installedApp(signing: .unknown, architecture: .unknown)], at: later)
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    /// Review M2 (zweite Runde): Team A → Scan mit ausgefallener Prüfung (Hauptprogramm geändert bzw. Zeitüberschreitung)
    /// → Team B. Der mittlere Snapshot gilt als äquivalent zu A und wird nur im Speicher aufgefrischt; der Wechsel muss
    /// trotzdem beim Vergleich mit ihm als Ereignis erscheinen.
    @Test(arguments: [true, false])
    func teamChangeAcrossAnUncheckedScanIsAnEvent(executableChanged: Bool) throws {
        let original = FileFingerprint(modified: Date(timeIntervalSince1970: 1_000), fileNumber: 1)
        let replaced = FileFingerprint(modified: Date(timeIntervalSince1970: 2_000), fileNumber: 2)
        var teamA = TestData.installedApp()
        teamA.executableFingerprint = original
        var unchecked = TestData.installedApp(origin: .unverified, signing: .unknown)
        unchecked.executableFingerprint = executableChanged ? replaced : original
        unchecked.signingLimitation = .notChecked
        var teamB = TestData.installedApp(signing: SigningInfo(kind: .developerID, teamID: "TEAMB67890", isNotarized: true))
        teamB.executableFingerprint = replaced

        let first = TestData.appSnapshot([teamA])
        let middle = TestData.appSnapshot([unchecked], at: later).carryingForwardAppState(from: first)
        if executableChanged {
            #expect(middle.installedApps.first?.signingLimitation == .changedSinceCheck)
        }
        #expect(middle.isEquivalent(to: first), "ausgefallene Prüfung ist kein Ereignis")
        #expect(differ.diff(from: first, to: middle).isEmpty)

        let last = TestData.appSnapshot([teamB], at: later + 60).carryingForwardAppState(from: middle)
        #expect(!last.isEquivalent(to: middle))
        let events = differ.diff(from: middle, to: last)
        #expect(events.map(\.kind) == [.modified])
        let after = try #require(last.installedApps.first)
        #expect(after.teamIDChange?.previousTeamID == "TEAMA12345")
    }

    @Test func firstListenerDeliveryIsBaseline() {
        let previous = TestData.networkSnapshot([], baseline: TestData.allSources)
        let current = TestData.networkSnapshot([TestData.listener()], at: later)
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    @Test func listenerAddedAndExposureChangeAreReported() {
        let local = TestData.listener(addresses: ["127.0.0.1"])
        let exposed = TestData.listener(addresses: ["0.0.0.0"])
        let added = differ.diff(from: TestData.networkSnapshot([]), to: TestData.networkSnapshot([local], at: later))
        #expect(added == [ChangeEvent(kind: .added, before: nil, after: .networkListener(local), detectedAt: later)])
        let modified = differ.diff(from: TestData.networkSnapshot([local]), to: TestData.networkSnapshot([exposed], at: later))
        #expect(modified.map(\.kind) == [.modified])
    }
}
