import Foundation
import Testing
@testable import ManagerKit

@Suite struct SnapshotSecurityCarryTests {
    private let now = TestData.date

    private func snapshot(_ checks: [SecurityCheck], at date: Date) -> Snapshot {
        var snapshot = TestData.snapshot(at: date)
        snapshot.securityChecks = checks
        return snapshot
    }

    private func carried(_ current: Snapshot, from previous: Snapshot?) -> Snapshot {
        current.carryingForwardSecurityState(from: previous, policy: .standard, now: current.takenAt)
    }

    @Test func firstSeenAtSurvivesScansAndRestartsForNewIdentifiers() {
        let day: TimeInterval = 86_400
        let first = snapshot([TestData.evaluatedCheck(
            .pendingUpdates(updates: [TestData.update("A", firstSeenAt: now)], lastCheck: now), now: now)], at: now)
        let later = now + 14 * day
        let rescanned = snapshot([TestData.evaluatedCheck(.pendingUpdates(
            updates: [TestData.update("A", firstSeenAt: later), TestData.update("B", firstSeenAt: later)], lastCheck: later),
            now: later)], at: later)

        let result = carried(rescanned, from: first).securityChecks[0]
        guard case .pendingUpdates(let updates, _)? = result.facts else { Issue.record("keine Fakten"); return }
        #expect(updates.map(\.firstSeenAt) == [now, later])  // A behält sein Datum, B beginnt neu
        #expect(result.state == .critical)                  // A ist jetzt 14 Tage alt
    }

    /// Ein Angebotsdatum aus der Plist, das früher liegt als das fortgeschriebene, gewinnt.
    @Test func earlierOfferDateWins() {
        let day: TimeInterval = 86_400
        let first = snapshot([TestData.evaluatedCheck(
            .pendingUpdates(updates: [TestData.update("A", firstSeenAt: now)], lastCheck: now))], at: now)
        let offered = now - 3 * day
        let rescanned = snapshot([TestData.evaluatedCheck(
            .pendingUpdates(updates: [TestData.update("A", firstSeenAt: offered)], lastCheck: now))], at: now + 60)
        let result = carried(rescanned, from: first).securityChecks[0]
        guard case .pendingUpdates(let updates, _)? = result.facts else { Issue.record("keine Fakten"); return }
        #expect(updates.map(\.firstSeenAt) == [offered])
    }

    @Test func failedCheckKeepsFactsAndLastKnownState() {
        let previous = snapshot([TestData.securityCheck(TestData.firewallOn, state: .good)], at: now)
        let current = snapshot([.failed(.firewall, detail: "Zeitüberschreitung")], at: now + 60)
        let result = carried(current, from: previous).securityChecks[0]
        #expect(result.state == .unknown && result.detail == "Zeitüberschreitung")
        #expect(result.facts == TestData.firewallOn && result.lastKnownState == .good)
        #expect(!previous.securityChecks[0].hasSignificantChanges(comparedTo: result))
    }

    @Test func lastKnownStateChainsAcrossRepeatedFailures() {
        let first = snapshot([TestData.securityCheck(TestData.firewallOn, state: .good)], at: now)
        let second = carried(snapshot([.failed(.firewall, detail: "x")], at: now + 60), from: first)
        let third = carried(snapshot([.failed(.firewall, detail: "y")], at: now + 120), from: second)
        #expect(third.securityChecks[0].lastKnownState == .good)
        #expect(third.securityChecks[0].facts == TestData.firewallOn)
    }

    @Test func withoutPreviousNothingIsCarried() {
        let current = snapshot([.failed(.sip, detail: "x")], at: now)
        #expect(carried(current, from: nil).securityChecks[0].lastKnownState == nil)
    }

    @Test func carryingIsIdempotent() {
        let previous = snapshot([TestData.securityCheck(TestData.firewallOn, state: .good)], at: now)
        let once = carried(snapshot([.failed(.firewall, detail: "x")], at: now + 60), from: previous)
        #expect(carried(once, from: previous) == once)
    }

    /// Auch der neu bewertete Zweig (Prüfung mit Fakten, `firstSeenAt` fortgeschrieben) ist idempotent.
    @Test func reevaluatedCarryingIsIdempotent() {
        let day: TimeInterval = 86_400
        let previous = snapshot([TestData.evaluatedCheck(
            .pendingUpdates(updates: [TestData.update("A", firstSeenAt: now)], lastCheck: now), now: now)], at: now)
        let later = now + 14 * day
        let current = snapshot([TestData.evaluatedCheck(
            .pendingUpdates(updates: [TestData.update("A", firstSeenAt: later)], lastCheck: later), now: later)], at: later)
        let once = carried(current, from: previous)
        #expect(once.securityChecks[0].state == .critical)
        #expect(carried(once, from: previous) == once)
    }
}
