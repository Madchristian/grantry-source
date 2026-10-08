import Foundation
import Testing
@testable import ManagerKit

@Suite struct SecurityPolicyTests {
    private let policy = {
        var policy = SecurityPolicy.standard
        policy.calendar = TestData.utcCalendar
        return policy
    }()
    private let now = TestData.date
    private func days(_ count: Double) -> TimeInterval { count * TestData.day }

    @Test(arguments: [
        (FileVaultStatus.on, SecurityState.good), (.encrypting, .warning), (.decrypting, .warning),
        (.pendingRestart, .warning), (.off, .critical),
    ])
    func fileVault(status: FileVaultStatus, expected: SecurityState) {
        #expect(policy.evaluate(.fileVault(status), now: now) == expected)
    }

    @Test func firewall() {
        #expect(policy.evaluate(TestData.firewallOn, now: now) == .good)
        #expect(policy.evaluate(TestData.stealthOff, now: now) == .warning)
        #expect(policy.evaluate(TestData.firewallOff, now: now) == .critical)
        #expect(policy.evaluate(.firewall(enabled: false, stealthMode: true), now: now) == .critical)
    }

    @Test func sipAndGatekeeper() {
        #expect(policy.evaluate(.sip(.enabled), now: now) == .good)
        #expect(policy.evaluate(.sip(.customConfiguration), now: now) == .warning)
        #expect(policy.evaluate(.sip(.disabled), now: now) == .critical)
        #expect(policy.evaluate(.gatekeeper(enabled: true), now: now) == .good)
        #expect(policy.evaluate(.gatekeeper(enabled: false), now: now) == .critical)
    }

    @Test(arguments: [(14.0, SecurityState.good), (15, .warning), (30, .warning), (31, .critical)])
    func xprotectAge(ageInDays: Double, expected: SecurityState) {
        #expect(policy.evaluate(.xprotect(version: "1", installedAt: now - days(ageInDays)), now: now) == expected)
    }

    /// Schwellen zählen in Kalendertagen wie die Anzeige: 14,5 Tage über 15 Tagesgrenzen sind „vor 15 Tagen“ und
    /// gelb, 14,6 Tage über 14 Tagesgrenzen „vor 14 Tagen“ und grün.
    @Test(arguments: [
        ("2026-09-15T20:00:00Z", "2026-09-30T08:00:00Z", SecurityState.warning),
        ("2026-09-16T06:00:00Z", "2026-09-30T20:00:00Z", .good),
    ])
    func xprotectAgeCountsCalendarDays(installed: String, at nowText: String, expected: SecurityState) throws {
        let installedAt = try Date(installed, strategy: .iso8601)
        let now = try Date(nowText, strategy: .iso8601)
        #expect(policy.evaluate(.xprotect(version: "1", installedAt: installedAt), now: now) == expected)
    }

    @Test func pendingUpdateBecomesCriticalOnTheFourteenthCalendarDay() throws {
        let firstSeen = try Date("2026-09-16T23:00:00Z", strategy: .iso8601)
        let update = TestData.update("A", firstSeenAt: firstSeen)
        let justBefore = try Date("2026-09-29T23:59:00Z", strategy: .iso8601)
        let nextMorning = try Date("2026-09-30T00:01:00Z", strategy: .iso8601)
        #expect(policy.evaluate(.pendingUpdates(updates: [update], lastCheck: justBefore), now: justBefore) == .warning)
        #expect(policy.evaluate(.pendingUpdates(updates: [update], lastCheck: nextMorning), now: nextMorning) == .critical)
    }

    @Test func automaticUpdates() {
        #expect(policy.evaluate(.automaticUpdates(disabled: []), now: now) == .good)
        #expect(policy.evaluate(.automaticUpdates(disabled: [.automaticallyInstallMacOSUpdates]), now: now) == .warning)
        #expect(policy.evaluate(.automaticUpdates(disabled: [.automaticDownload]), now: now) == .warning)
        for key in [SoftwareUpdateKey.automaticCheckEnabled, .criticalUpdateInstall, .configDataInstall] {
            #expect(policy.evaluate(.automaticUpdates(disabled: [key]), now: now) == .critical)
        }
    }

    @Test(arguments: [(7.0, SecurityState.good), (8, .warning)])
    func lastCheckAgeWithoutPendingUpdates(ageInDays: Double, expected: SecurityState) {
        #expect(policy.evaluate(.pendingUpdates(updates: [], lastCheck: now - days(ageInDays)), now: now) == expected)
    }

    @Test func neverCheckedIsWarning() {
        #expect(policy.evaluate(.pendingUpdates(updates: [], lastCheck: nil), now: now) == .warning)
    }

    @Test(arguments: [(13.0, SecurityState.warning), (14, .critical)])
    func pendingUpdateAge(ageInDays: Double, expected: SecurityState) {
        let update = TestData.update("A", firstSeenAt: now - days(ageInDays))
        #expect(policy.evaluate(.pendingUpdates(updates: [update], lastCheck: now), now: now) == expected)
    }

    @Test func mdmIsAlwaysGood() {
        #expect(policy.evaluate(.mdmEnrollment(enrolled: true, viaDEP: true), now: now) == .good)
        #expect(policy.evaluate(.mdmEnrollment(enrolled: false, viaDEP: false), now: now) == .good)
    }

    @Test func realFixturesOnTheTestMacAreGreenExceptPendingUpdates() throws {
        let now = try Date("2026-09-30T16:00:00Z", strategy: .iso8601)
        let preferences = try SoftwareUpdatePreferences(data: securityFixtureData("SoftwareUpdate.plist"))
        let updates = preferences.pendingUpdates(firstSeenFallback: now)
        #expect(policy.evaluate(.pendingUpdates(updates: updates, lastCheck: preferences.lastSuccessfulCheck), now: now) == .warning)
        #expect(policy.evaluate(try SecurityParsers.xprotect(securityFixture("xprotect-version.json")), now: now) == .good)
    }
}
