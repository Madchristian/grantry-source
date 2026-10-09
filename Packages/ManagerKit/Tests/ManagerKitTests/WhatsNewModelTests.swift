import Testing
@testable import ManagerKit

@MainActor
struct WhatsNewModelTests {
    @Test func existingInstallationShowsOnceAndAcknowledgementSurvivesRestart() {
        let settings = InMemorySettingsStore()
        let model = WhatsNewModel(version: "2026.10.91", hasCompletedOnboarding: true, defaults: settings)
        model.presentIfNeeded(canPresent: true)
        #expect(model.isPresented)
        model.dismiss()
        let restarted = WhatsNewModel(version: "2026.10.91", hasCompletedOnboarding: true, defaults: settings)
        restarted.presentIfNeeded(canPresent: true)
        #expect(!restarted.isPresented)
        restarted.present()
        #expect(restarted.isPresented)
    }

    @Test func firstInstallationDoesNotShowButNextVersionDoes() {
        let settings = InMemorySettingsStore()
        let fresh = WhatsNewModel(version: "2026.10.91", hasCompletedOnboarding: false, defaults: settings)
        fresh.presentIfNeeded(canPresent: true)
        #expect(!fresh.isPresented)
        let next = WhatsNewModel(version: "2026.10.92", hasCompletedOnboarding: true, defaults: settings)
        next.presentIfNeeded(canPresent: true)
        #expect(next.isPresented)
    }

    @Test func otherSheetsDeferAutomaticPresentationWithoutConsumingIt() {
        let settings = InMemorySettingsStore()
        let model = WhatsNewModel(version: "2026.10.91", hasCompletedOnboarding: true, defaults: settings)
        model.presentIfNeeded(canPresent: false)
        #expect(!model.isPresented)
        model.presentIfNeeded(canPresent: true)
        #expect(model.isPresented)
        model.dismiss()
        model.presentIfNeeded(canPresent: true)
        #expect(!model.isPresented)
    }

    @Test func closingWindowWithoutAcknowledgingKeepsUpdatePending() {
        let settings = InMemorySettingsStore()
        let model = WhatsNewModel(version: "2026.10.91", hasCompletedOnboarding: true, defaults: settings)
        model.presentIfNeeded(canPresent: true)
        let restarted = WhatsNewModel(version: "2026.10.91", hasCompletedOnboarding: true, defaults: settings)
        restarted.presentIfNeeded(canPresent: true)
        #expect(restarted.isPresented)
    }
}
