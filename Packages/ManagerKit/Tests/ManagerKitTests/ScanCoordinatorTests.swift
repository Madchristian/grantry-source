import Testing
import Foundation
import Synchronization
import TestSupport
@testable import ManagerKit

struct FixedSource: InventorySource {
    let id: SourceID
    let result: Result<InventoryContribution, TestFailure>
    func collect() async throws -> InventoryContribution { try result.get() }
}

/// Wartet, bis der umgebende Task abgebrochen wird, und reicht den `CancellationError` weiter.
private struct HangingSource: InventorySource {
    let id: SourceID = .launchd
    func collect() async throws -> InventoryContribution {
        try await Task.sleep(for: .seconds(3600))
        return InventoryContribution()
    }
}

/// Antwortet nie und ignoriert den Abbruch – wie eine Quelle, die an einem Systemaufruf hängt.
private struct UnresponsiveSource: InventorySource {
    let id: SourceID = .launchd
    let latch: Latch
    func collect() async throws -> InventoryContribution {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                latch.wait()
                continuation.resume()
            }
        }
        return InventoryContribution()
    }
}

/// Wie `UnresponsiveSource`, zählt aber die Aufrufe von `collect()` und meldet jedes Ende.
private final class CountingUnresponsiveSource: InventorySource {
    let id: SourceID = .launchd
    let latch = Latch()
    /// Öffnet sich bei jedem Ende von `collect()`; der Test wartet suspendierend darauf (nie blockierend im
    /// kooperativen Pool, der die Fortsetzung von `collect()` ausführen muss).
    let finished = Gate()
    private let calls = Mutex(0)

    var callCount: Int { calls.withLock { $0 } }

    func collect() async throws -> InventoryContribution {
        calls.withLock { $0 += 1 }
        let latch = latch
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                latch.wait()
                continuation.resume()
            }
        }
        finished.open()
        return InventoryContribution(autostartItems: [TestData.item("com.example.late", source: .launchd)])
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String { "kaputt" }
}

private struct DescribedFailure: LocalizedError {
    var errorDescription: String? { "lesbare Beschreibung" }
}

private struct DescribedSource: InventorySource {
    let id: SourceID = .tccUser
    func collect() async throws -> InventoryContribution { throw DescribedFailure() }
}

@Suite struct ScanCoordinatorTests {
    @Test func mergesContributionsOfAllSources() async throws {
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .tccUser, result: .success(InventoryContribution(grants: [TestData.grant()]))),
            FixedSource(id: .launchd, result: .success(InventoryContribution(autostartItems: [TestData.item()]))),
        ], now: { TestData.date })

        let snapshot = try await coordinator.scan()

        #expect(snapshot.takenAt == TestData.date)
        #expect(snapshot.grants == [TestData.grant()])
        #expect(snapshot.autostartItems == [TestData.item()])
        #expect(snapshot.sourceErrors.isEmpty)
    }

    @Test func mergesInstalledApps() async throws {
        let app = TestData.installedApp()
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .apps, result: .success(InventoryContribution(installedApps: [app]))),
        ], now: { TestData.date })

        let snapshot = try await coordinator.scan()

        #expect(snapshot.installedApps == [app])
        #expect(snapshot.baselineSources == [.apps])
    }

    /// Review M3: Nur die Apps eines nicht lesbaren Ordners werden fortgeschrieben; eine App aus einem gelesenen Ordner,
    /// die fehlt, gilt als entfernt.
    @Test func carriesAppsOfIncompleteFoldersForward() async throws {
        let locked = TestData.installedApp("Locked", path: "/Applications/Vendor/Locked.app")
        let lockedPrefix = TestData.installedApp("Prefix", path: "/Applications/Vendor Tools/Prefix.app")
        let removed = TestData.installedApp("Removed", bundleID: "com.example.removed")
        let kept = TestData.installedApp("Kept", bundleID: "com.example.kept")
        let previous = TestData.appSnapshot([locked, lockedPrefix, removed, kept])
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .apps, result: .success(InventoryContribution(installedApps: [kept],
                                                                          incompleteFolders: ["/Applications/Vendor"]))),
        ], now: { TestData.date + TestData.day })

        let snapshot = try await coordinator.scan(previous: previous)

        #expect(snapshot.installedApps.map(\.name) == ["Kept", "Locked"])
        #expect(snapshot.sourceErrors.isEmpty)
    }

    @Test func carriesAppStateForward() async throws {
        let previous = TestData.appSnapshot([TestData.installedApp()])
        let teamB = TestData.installedApp(signing: SigningInfo(kind: .developerID, teamID: "TEAMB67890", isNotarized: true))
        let snapshot = try await ScanCoordinator(sources: [
            FixedSource(id: .apps, result: .success(InventoryContribution(installedApps: [teamB]))),
        ], now: { TestData.date + 60 }).scan(previous: previous)

        #expect(snapshot.installedApps.first?.teamIDChange == TeamIDChange(previousTeamID: "TEAMA12345",
                                                                          detectedAt: TestData.date + 60))
    }

    /// Lauscher landen im Snapshot; fehlt einer im nächsten Scan, schreibt die Entprellung ihn fort.
    @Test func mergesAndDebouncesNetworkListeners() async throws {
        let listener = TestData.listener()
        let first = try await ScanCoordinator(sources: [
            FixedSource(id: .networkListeners, result: .success(InventoryContribution(networkListeners: [listener]))),
        ], currentUID: 501, now: { TestData.date }).scan()

        #expect(first.networkListeners == [listener])
        #expect(first.baselineSources.contains(.networkListeners))

        let second = try await ScanCoordinator(sources: [
            FixedSource(id: .networkListeners, result: .success(InventoryContribution())),
        ], currentUID: 501, now: { TestData.date + 60 }).scan(previous: first)

        #expect(second.networkListeners == [listener])
    }

    /// Nur eigene Sockets lesbar (`listenersLimitedToUID`): Lauscher anderer Benutzer bleiben unabhängig vom Alter.
    @Test func limitedListenerScanKeepsOtherUsers() async throws {
        let root = TestData.listener("/usr/local/sbin/daemon", uid: 0)
        let snapshot = try await ScanCoordinator(sources: [
            FixedSource(id: .networkListeners,
                        result: .success(InventoryContribution(listenersLimitedToUID: 501))),
        ], currentUID: 501, now: { TestData.date + TestData.day }).scan(previous: TestData.networkSnapshot([root]))

        #expect(snapshot.networkListeners == [root])
    }

    /// Die erste vollständige Lieferung (alle Benutzer) setzt `hasCompleteListenerBaseline`; eingeschränkte und
    /// gescheiterte Scans schreiben das Flag fort, ein Teilscan ebenso.
    @Test func completeListenerScanSetsTheBaselineFlagForGood() async throws {
        let limited = FixedSource(id: .networkListeners, result: .success(InventoryContribution(listenersLimitedToUID: 501)))
        let first = try await ScanCoordinator(sources: [limited], currentUID: 501, now: { TestData.date }).scan()
        #expect(!first.hasCompleteListenerBaseline)

        let complete = FixedSource(id: .networkListeners, result: .success(InventoryContribution()))
        let second = try await ScanCoordinator(sources: [complete], currentUID: 501, now: { TestData.date + 60 })
            .scan(previous: first)
        #expect(second.hasCompleteListenerBaseline)

        let third = try await ScanCoordinator(sources: [limited], currentUID: 501, now: { TestData.date + 120 })
            .scan(previous: second, only: [.networkListeners])
        #expect(third.hasCompleteListenerBaseline)

        let failing = FixedSource(id: .networkListeners, result: .failure(TestFailure()))
        let fourth = try await ScanCoordinator(sources: [failing], currentUID: 501, now: { TestData.date + 180 })
            .scan(previous: third)
        #expect(fourth.hasCompleteListenerBaseline)
    }

    /// Fällt die Quelle aus, wird nicht entprellt: `carryingForwardRecords` übernimmt alle Lauscher unabhängig vom Alter.
    @Test func failedListenerSourceCarriesListenersForward() async throws {
        let listener = TestData.listener()
        let snapshot = try await ScanCoordinator(sources: [
            FixedSource(id: .networkListeners, result: .failure(TestFailure())),
        ], currentUID: 501, now: { TestData.date + TestData.day }).scan(previous: TestData.networkSnapshot([listener]))

        #expect(snapshot.networkListeners == [listener])
        #expect(snapshot.sourceErrors == [SourceError(source: .networkListeners, message: "kaputt")])
    }

    /// „Prozess beenden …“: Gemeldete beendete Lauscher werden nicht entprellt – auch fremde bei eingeschränktem Scan.
    @Test func endedListenersAreDroppedInsteadOfCarried() async throws {
        let node = TestData.listener()
        let root = TestData.listener("/usr/local/sbin/daemon", uid: 0)
        let ended = InventoryContribution(listenersLimitedToUID: 501, endedListenerIDs: [node.id, root.id])
        let snapshot = try await ScanCoordinator(sources: [
            FixedSource(id: .networkListeners, result: .success(ended)),
        ], currentUID: 501, now: { TestData.date.addingTimeInterval(60) })
            .scan(previous: TestData.networkSnapshot([node, root]))

        #expect(snapshot.networkListeners.isEmpty)
    }

    @Test func isolatesFailingSource() async throws {
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .btm, result: .failure(TestFailure())),
            FixedSource(id: .launchd, result: .success(InventoryContribution(autostartItems: [TestData.item()]))),
        ], now: { TestData.date })

        let snapshot = try await coordinator.scan()

        #expect(snapshot.autostartItems == [TestData.item()])
        #expect(snapshot.sourceErrors == [SourceError(source: .btm, message: "kaputt")])
    }

    @Test func prefersLocalizedErrorDescriptionAsMessage() async throws {
        let snapshot = try await ScanCoordinator(sources: [DescribedSource()], now: { TestData.date }).scan()

        #expect(snapshot.sourceErrors == [SourceError(source: .tccUser, message: "lesbare Beschreibung")])
    }

    @Test func carriesForwardRecordsOfFailedSourceFromPrevious() async throws {
        let previousItem = TestData.item("com.docker.docker", kind: .loginItem, source: .btm)
        let previous = TestData.snapshot(items: [previousItem])
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .btm, result: .failure(TestFailure())),
        ], now: { TestData.date })

        let snapshot = try await coordinator.scan(previous: previous)

        #expect(snapshot.autostartItems == [previousItem])
        #expect(snapshot.failedSources == [.btm])
    }

    @Test func resultOrderIsStableRegardlessOfCompletionOrder() async throws {
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .launchd, result: .success(InventoryContribution(autostartItems: [TestData.item("b")]))),
            FixedSource(id: .btm, result: .success(InventoryContribution(autostartItems: [TestData.item("a", kind: .loginItem, source: .btm)]))),
        ], now: { TestData.date })
        let labels = try await coordinator.scan().autostartItems.map(\.label)
        #expect(labels == ["b", "a"])
    }

    /// Regression (Release-Build 187): Jedes Ergebnis gehört zu seiner Quelle – kein Ergebnis wird verworfen oder
    /// einer anderen Quelle zugeordnet. Unter `-O` kam der Index aus einem `(Int, Outcome)`-Tupel der Task-Gruppe
    /// falsch an; `compactMap` verschob dann die Zuordnung in `zip(sources, outcomes)`.
    @Test func attributesEveryOutcomeToItsOwnSource() async throws {
        let agent = TestData.item("com.example.agent", source: .launchd)
        let docker = TestData.item("com.docker.docker", kind: .loginItem, source: .btm)
        let check = TestData.securityCheck(TestData.firewallOn, state: .good)
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .tccSystem, result: .success(InventoryContribution(grants: [TestData.grant()]))),
            FixedSource(id: .launchd, result: .success(InventoryContribution(autostartItems: [agent]))),
            FixedSource(id: .btm, result: .failure(TestFailure())),
            FixedSource(id: .securityPosture, result: .success(InventoryContribution(securityChecks: [check]))),
        ], now: { TestData.date })

        let snapshot = try await coordinator.scan(previous: TestData.snapshot(items: [docker]))

        #expect(snapshot.grants == [TestData.grant()])
        #expect(snapshot.autostartItems == [agent, docker])
        #expect(snapshot.securityChecks.map(\.kind) == [.firewall])
        #expect(snapshot.sourceErrors == [SourceError(source: .btm, message: "kaputt")])
        #expect(snapshot.baselineSources.isSuperset(of: [.tccSystem, .launchd, .securityPosture]))
    }

    @Test func cancellationIsThrownInsteadOfRecordedAsSourceError() async {
        let coordinator = ScanCoordinator(sources: [
            HangingSource(),
            FixedSource(id: .tccUser, result: .success(InventoryContribution(grants: [TestData.grant()]))),
        ], now: { TestData.date })

        let scan = Task { try await coordinator.scan() }
        scan.cancel()

        await #expect(throws: CancellationError.self) { try await scan.value }
    }

    /// Review N5: Eine hängende Quelle hält den Scan höchstens ihre Frist auf – danach Quellenfehler, ihre Einträge
    /// werden fortgeschrieben, die übrigen Quellen liefern normal.
    @Test(.timeLimit(.minutes(1))) func unresponsiveSourceTimesOutAndIsCarriedForward() async throws {
        let latch = Latch()
        let previousItem = TestData.item("com.example.agent", source: .launchd)
        let coordinator = ScanCoordinator(sources: [
            UnresponsiveSource(latch: latch),
            FixedSource(id: .tccUser, result: .success(InventoryContribution(grants: [TestData.grant()]))),
        ], sourceTimeout: .milliseconds(200), now: { TestData.date })

        let start = ContinuousClock.now
        let snapshot = try await coordinator.scan(previous: TestData.snapshot(items: [previousItem]))
        latch.release()

        #expect(ContinuousClock.now - start < LatencyBound.wellBeforeLongTimeouts)
        #expect(snapshot.grants == [TestData.grant()])
        #expect(snapshot.autostartItems == [previousItem])
        #expect(snapshot.sourceErrors == [SourceError(source: .launchd, message: "Zeitüberschreitung: keine Antwort nach 0,2 s")])
    }

    /// Review N4: Läuft eine Quelle nach Fristablauf noch, startet der nächste Scan sie nicht erneut, sondern meldet
    /// sofort „läuft noch“; erst nach ihrem Ende wird sie wieder gefragt.
    @Test(.timeLimit(.minutes(1))) func sourceStillRunningAfterItsDeadlineIsNotStartedAgain() async throws {
        let source = CountingUnresponsiveSource()
        let coordinator = ScanCoordinator(sources: [source], sourceTimeout: .milliseconds(200), now: { TestData.date })

        let first = try await coordinator.scan()
        #expect(first.sourceErrors.map(\.message) == ["Zeitüberschreitung: keine Antwort nach 0,2 s"])

        let start = ContinuousClock.now
        let second = try await coordinator.scan(previous: first)
        #expect(ContinuousClock.now - start < .milliseconds(150), "ohne erneute Frist")
        #expect(second.sourceErrors == [SourceError(source: .launchd, message: ScanCoordinator.stillRunningMessage)])
        #expect(source.callCount == 1)

        // Ein Signal beendet die hängende Abfrage, das zweite lässt die nächste sofort durch.
        source.latch.release(2)
        try await source.finished.wait()
        // Das Ende der Quelle gibt sie frei (der Merker fällt unmittelbar nach `collect()`).
        var third = try await coordinator.scan(previous: second)
        for _ in 0..<50 where third.sourceErrors.first?.message == ScanCoordinator.stillRunningMessage {
            try await Task.sleep(for: .milliseconds(20))
            third = try await coordinator.scan(previous: second)
        }
        #expect(source.callCount == 2)
        #expect(third.autostartItems.map(\.label) == ["com.example.late"])
    }

    @Test func defaultSourceTimeoutIsTwoMinutes() {
        #expect(ScanCoordinator.defaultSourceTimeout == .seconds(120))
        #expect(ScanCoordinator.timeoutMessage(.seconds(120)) == "Zeitüberschreitung: keine Antwort nach 120 s")
    }

    @Test func firstScanUsesSuccessfulSourcesAsBaseline() async throws {
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .btm, result: .failure(TestFailure())),
            FixedSource(id: .launchd, result: .success(InventoryContribution())),
        ], now: { TestData.date })

        #expect(try await coordinator.scan().baselineSources == [.launchd])
    }

    @Test func baselineAccumulatesAcrossScans() async throws {
        let previous = TestData.snapshot(baseline: [.btm, .tccUser])
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .btm, result: .failure(TestFailure())),
            FixedSource(id: .launchd, result: .success(InventoryContribution())),
        ], now: { TestData.date })

        #expect(try await coordinator.scan(previous: previous).baselineSources == [.btm, .tccUser, .launchd])
    }

    @Test func sourceDeliveringForTheFirstTimeProducesNoAdditions() async throws {
        let agent = TestData.item("com.example.agent", source: .launchd)
        let docker = TestData.item("com.docker.docker", kind: .loginItem, source: .btm)
        let dropbox = TestData.item("com.dropbox.client", kind: .loginItem, source: .btm)
        let launchd = FixedSource(id: .launchd, result: .success(InventoryContribution(autostartItems: [agent])))
        let differ = SnapshotDiffer()

        let s1 = try await ScanCoordinator(sources: [launchd, FixedSource(id: .btm, result: .failure(TestFailure()))]).scan()
        let s2 = try await ScanCoordinator(sources: [
            launchd, FixedSource(id: .btm, result: .success(InventoryContribution(autostartItems: [docker]))),
        ]).scan(previous: s1)
        #expect(differ.diff(from: s1, to: s2).isEmpty)

        let s3 = try await ScanCoordinator(sources: [
            launchd, FixedSource(id: .btm, result: .success(InventoryContribution(autostartItems: [docker, dropbox]))),
        ]).scan(previous: s2)
        #expect(differ.diff(from: s2, to: s3).map(\.subject) == [.autostartItem(dropbox)])
    }
}

private struct FixedSecuritySource: InventorySource {
    let id: SourceID = .securityPosture
    let checks: [SecurityCheck]
    func collect() async throws -> InventoryContribution { InventoryContribution(securityChecks: checks) }
}

extension ScanCoordinatorTests {
    @Test func collectsSecurityChecksAndCarriesUnknownForward() async throws {
        let date = TestData.date
        let first = try await ScanCoordinator(
            sources: [FixedSecuritySource(checks: [TestData.securityCheck(TestData.firewallOn, state: .good)])], now: { date }
        ).scan()
        #expect(first.baselineSources == [.securityPosture])
        #expect(first.securityChecks.map(\.kind) == [.firewall])
        let second = try await ScanCoordinator(
            sources: [FixedSecuritySource(checks: [.failed(.firewall, detail: "x")])], now: { date + 60 }
        ).scan(previous: first)
        #expect(second.securityChecks.first?.lastKnownState == .good)
        #expect(second.securityChecks.first?.facts == TestData.firewallOn)
        #expect(second.isEquivalent(to: first))
    }

    /// Die Ampel wird nach dem Carry-Forward zum Scan-Zeitpunkt neu bewertet.
    @Test func reevaluatesSecurityStateAfterCarryForward() async throws {
        let date = TestData.date
        let later = date + 14 * 86_400
        let update = TestData.update("A", firstSeenAt: date)
        let first = try await ScanCoordinator(sources: [FixedSecuritySource(checks: [
            TestData.evaluatedCheck(.pendingUpdates(updates: [update], lastCheck: date), now: date),
        ])], now: { date }).scan()
        let fresh = TestData.update("A", firstSeenAt: later)
        let second = try await ScanCoordinator(sources: [FixedSecuritySource(checks: [
            TestData.evaluatedCheck(.pendingUpdates(updates: [fresh], lastCheck: later), now: later),
        ])], now: { later }).scan(previous: first)
        #expect(second.securityChecks.first?.state == .critical)
    }
}

/// Review M2: Einschränkungen einer Quelle (etwa ausgefallene Signaturprüfungen) erscheinen im Snapshot, ohne die
/// Quelle als fehlgeschlagen zu werten.
@Suite struct ScanLimitationTests {
    @Test func limitationsAreReportedWithoutFailingTheSource() async throws {
        let snapshot = try await ScanCoordinator(sources: [
            FixedSource(id: .apps, result: .success(InventoryContribution(installedApps: [TestData.installedApp()],
                                                                          limitations: ["Prüfung eingeschränkt"]))),
        ], now: { TestData.date }).scan()

        #expect(snapshot.sourceLimitations == [SourceLimitation(source: .apps, message: "Prüfung eingeschränkt")])
        #expect(snapshot.sourceErrors.isEmpty)
        #expect(snapshot.failedSources.isEmpty)
        #expect(snapshot.isEquivalent(to: TestData.appSnapshot([TestData.installedApp()], baseline: [.apps])))
    }

    @Test func limitationsRoundTripAndOlderSnapshotsDecode() throws {
        var snapshot = TestData.appSnapshot([])
        snapshot.sourceLimitations = [SourceLimitation(source: .apps, message: "x")]
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(Snapshot.self, from: encoded) == snapshot)
        var legacy = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["sourceLimitations"] = nil
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.sourceLimitations.isEmpty)
    }
}
