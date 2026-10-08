import Foundation
import Testing
@testable import ManagerKit

@Suite struct UpdatePreferencesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(build: Int) throws -> AppcastItem {
        let data = AppcastParserTests.feed(AppcastParserTests.item(build: String(build)))
        return try #require(try AppcastParser.items(from: data).first)
    }

    @Test func consentStartsUndecidedAndPersists() {
        let store = InMemorySettingsStore()
        #expect(UpdatePreferences(store: store).consent == .undecided)
        UpdatePreferences(store: store).consent = .enabled
        #expect(UpdatePreferences(store: store).consent == .enabled)
    }

    @Test func checkAndNotificationStateSurviveANewInstance() throws {
        let store = InMemorySettingsStore()
        let first = UpdatePreferences(store: store)
        first.lastSuccessfulCheck = now
        #expect(first.claimNotification(for: try item(build: 280)))

        let second = UpdatePreferences(store: store)
        #expect(second.lastSuccessfulCheck == now)
        #expect(second.lastNotifiedBuild == 280)
    }

    @Test(arguments: [UpdateConsent.undecided, .disabled])
    func neverDueWithoutConsent(consent: UpdateConsent) {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        preferences.consent = consent
        #expect(!preferences.isCheckDue(now: now))
    }

    @Test func dueWithoutEarlierCheckAndAfterTheInterval() {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        preferences.consent = .enabled
        #expect(preferences.isCheckDue(now: now))
        preferences.lastSuccessfulCheck = now.addingTimeInterval(-UpdatePreferences.checkInterval + 60)
        #expect(!preferences.isCheckDue(now: now))
        preferences.lastSuccessfulCheck = now.addingTimeInterval(-UpdatePreferences.checkInterval)
        #expect(preferences.isCheckDue(now: now))
    }

    @Test func dueWhenTheLastCheckLiesInTheFuture() {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        preferences.consent = .enabled
        preferences.lastSuccessfulCheck = now.addingTimeInterval(60)
        #expect(preferences.isCheckDue(now: now))
    }

    @Test func claimsEachVersionOnce() throws {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        #expect(preferences.claimNotification(for: try item(build: 280)))
        #expect(!preferences.claimNotification(for: try item(build: 280)))
        #expect(!preferences.claimNotification(for: try item(build: 279)))
        #expect(preferences.claimNotification(for: try item(build: 281)))
        #expect(preferences.lastNotifiedBuild == 281)
    }
}
