import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Review M2: Fällt die Signaturprüfung aus (Zeitüberschreitung, erschöpfter Guard), darf der Scan die alte Signatur
/// nicht stillschweigend als aktuell fortschreiben – und nach einem Austausch des Hauptprogramms gar nicht.
@Suite struct AppSigningCarryTests {
    private let original = FileFingerprint(modified: Date(timeIntervalSince1970: 1_000), fileNumber: 1)
    private let replaced = FileFingerprint(modified: Date(timeIntervalSince1970: 2_000), fileNumber: 2)
    private let teamB = SigningInfo(kind: .developerID, teamID: "TEAMB67890", isNotarized: true)

    private func app(
        signing: SigningInfo = TestData.developerSigning, origin: AppOrigin = .direct,
        executable: FileFingerprint?, limitation: SigningLimitation? = nil
    ) -> InstalledApp {
        var app = TestData.installedApp(origin: origin, signing: signing)
        app.executableFingerprint = executable
        app.signingLimitation = limitation
        return app
    }

    /// Ausgefallene Prüfung ohne Prüfergebnis, wie sie `AppInventorySource` liefert.
    private func unchecked(executable: FileFingerprint?) -> InstalledApp {
        app(signing: .unknown, origin: .unverified, executable: executable, limitation: .notChecked)
    }

    private func snapshot(_ app: InstalledApp, day: Double) -> Snapshot {
        TestData.appSnapshot([app], at: TestData.date + day * TestData.day)
    }

    @Test func unchangedExecutableCarriesTheSignatureAsStale() throws {
        let verified = snapshot(app(executable: original), day: 0)
        let first = snapshot(unchecked(executable: original), day: 1).carryingForwardAppState(from: verified)
        let carried = try #require(first.installedApps.first)
        #expect(carried.signing == TestData.developerSigning)
        #expect(carried.origin == .direct)
        #expect(carried.signingLimitation == .carriedForward(verifiedAt: TestData.date))
        #expect(first.carryingForwardAppState(from: verified) == first, "idempotent")

        let second = snapshot(unchecked(executable: original), day: 2).carryingForwardAppState(from: first)
        #expect(second.installedApps.first?.signingLimitation == .carriedForward(verifiedAt: TestData.date),
                "bleibt beim Zeitpunkt der letzten echten Prüfung")

        let checked = snapshot(app(executable: original), day: 3).carryingForwardAppState(from: second)
        #expect(checked.installedApps.first?.signingLimitation == nil)
    }

    @Test func changedExecutableDoesNotInheritTheSignature() throws {
        let verified = snapshot(app(executable: original), day: 0)
        let changed = snapshot(unchecked(executable: replaced), day: 1).carryingForwardAppState(from: verified)
        let app = try #require(changed.installedApps.first)
        #expect(app.signing == .unknown)
        #expect(app.origin == .unverified)
        #expect(app.lastKnownTeamID == "TEAMA12345")
        #expect(app.signingLimitation == .changedSinceCheck)
        #expect(changed.carryingForwardAppState(from: verified) == changed, "idempotent")

        let still = snapshot(unchecked(executable: replaced), day: 2).carryingForwardAppState(from: changed)
        #expect(still.installedApps.first?.signingLimitation == .changedSinceCheck)
        #expect(still.installedApps.first?.lastKnownTeamID == "TEAMA12345")

        let teamBApp = self.app(signing: teamB, executable: replaced)
        let revealed = snapshot(teamBApp, day: 3).carryingForwardAppState(from: still)
        #expect(revealed.installedApps.first?.teamIDChange == TeamIDChange(previousTeamID: "TEAMA12345",
                                                                           detectedAt: TestData.date + 3 * TestData.day))
        #expect(revealed.installedApps.first?.signingLimitation == nil)
    }

    @Test func noPreviousLeavesTheAppUnchecked() {
        let first = snapshot(unchecked(executable: original), day: 0).carryingForwardAppState(from: nil)
        #expect(first.installedApps.first?.signingLimitation == .notChecked)
    }

    @Test func limitationIsNotSignificantAndDecodesFromOlderSnapshots() throws {
        let fresh = app(executable: original)
        let stale = app(executable: replaced, limitation: .carriedForward(verifiedAt: TestData.date))
        #expect(!fresh.hasSignificantChanges(comparedTo: stale))

        let encoded = try JSONEncoder().encode(stale)
        #expect(try JSONDecoder().decode(InstalledApp.self, from: encoded) == stale)
        var legacy = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["signingLimitation"] = nil
        legacy["executableFingerprint"] = nil
        let decoded = try JSONDecoder().decode(InstalledApp.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.signingLimitation == nil)
        #expect(decoded.executableFingerprint == nil)
    }

    @Test func statusNoteExplainsTheLimitation() {
        let now = TestData.date + 3 * TestData.day
        #expect(app(executable: nil).signingStatusNote(now: now) == nil)
        #expect(unchecked(executable: nil).signingStatusNote(now: now) == "Signatur nicht geprüft (Zeitüberschreitung)")
        #expect(app(executable: nil, limitation: .carriedForward(verifiedAt: TestData.date)).signingStatusNote(now: now)
            == "Signatur nicht geprüft seit 3 Tagen")
        #expect(app(executable: nil, limitation: .changedSinceCheck).signingStatusNote(now: now)
            == "Signatur nach Änderung nicht prüfbar")
    }
}

/// Die Quelle markiert ausgefallene Prüfungen und meldet sie als Einschränkung des Scans.
@Suite struct AppInventorySigningLimitationTests {
    @Test func timedOutInspectionIsMarkedAndReported() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            try AppFixture.make(in: root, named: "Slow", bundleID: "com.example.slow")
            let source = AppInventorySource(roots: [.init(path: root.path, location: .applications)],
                                            inspector: ScriptedSigningInspector([.timedOut]), caskrooms: [])
            let contribution = try await source.collect()
            let app = try #require(contribution.installedApps.first)
            #expect(app.signing == .unknown)
            #expect(app.signingLimitation == .notChecked)
            #expect(app.executableFingerprint != nil)
            #expect(contribution.retryableLimitations == [
                "Prüfung eingeschränkt: Signatur von 1 App nicht geprüft (Zeitüberschreitung), zuletzt bekannte Werte gelten weiter",
            ])
        }
    }

    @Test func exhaustedGuardIsReported() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            let callGuard = BlockingCallGuard(maximumHanging: 1)
            let latch = Latch()
            #expect(callGuard.run(timeout: .milliseconds(20)) { latch.wait() } == nil)
            let source = AppInventorySource(roots: [.init(path: root.path, location: .applications)],
                                            inspector: ScriptedSigningInspector([.completed(.unknown)]), caskrooms: [],
                                            names: BundleNameReader(), signingGuard: callGuard)
            let limitations = try await source.collect().retryableLimitations
            latch.release()
            #expect(limitations == ["Prüfung eingeschränkt: Signaturprüfung ausgesetzt, bis hängende Prüfungen enden"])
        }
    }

    /// Review N5: Ein erschöpfter Guard der Tiefenprüfung erscheint ebenfalls als Einschränkung des Scans.
    @Test func exhaustedDeepValidationGuardIsReported() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            let deepGuard = BlockingCallGuard(maximumHanging: 1)
            let latch = Latch()
            #expect(deepGuard.run(timeout: .milliseconds(20)) { latch.wait() } == nil)
            let source = AppInventorySource(roots: [.init(path: root.path, location: .applications)],
                                            inspector: ScriptedSigningInspector([.completed(.unknown)]), caskrooms: [],
                                            names: BundleNameReader(), signingGuard: BlockingCallGuard(maximumHanging: 1),
                                            deepValidationGuard: deepGuard)
            let limitations = try await source.collect().retryableLimitations
            latch.release()
            #expect(limitations == [
                "Prüfung eingeschränkt: Tiefenprüfung der Signaturen ausgesetzt, bis hängende Prüfungen enden",
            ])
        }
    }

    @Test func completedInspectionIsNotLimited() async throws {
        try await ScratchDirectory.with(prefix: "apps") { root in
            try AppFixture.make(in: root, named: "Fast", bundleID: "com.example.fast")
            let source = AppInventorySource(roots: [.init(path: root.path, location: .applications)],
                                            inspector: ScriptedSigningInspector([.completed(.unknown)]), caskrooms: [])
            let contribution = try await source.collect()
            #expect(contribution.installedApps.first?.signingLimitation == nil)
            #expect(contribution.limitations.isEmpty)
        }
    }
}
