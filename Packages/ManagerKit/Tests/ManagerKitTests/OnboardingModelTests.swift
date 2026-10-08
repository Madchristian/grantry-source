import Foundation
import Testing
import ManagerKit

@MainActor
@Suite struct OnboardingModelTests {
    private static let complete = SetupChecklist(
        SetupStatus(fullDiskAccess: true, helper: .ready, notifications: .authorized, launchAtLogin: .enabled)
    )
    private static let missingFullDiskAccess = SetupChecklist(
        SetupStatus(fullDiskAccess: false, helper: .ready, notifications: .authorized, launchAtLogin: .enabled)
    )

    @Test func firstLaunchPresentsOnce() {
        let defaults = InMemorySettingsStore()
        let model = OnboardingModel(defaults: defaults) {}
        model.presentIfNeeded(Self.complete)
        #expect(model.isPresented)
        model.postpone()
        model.presentIfNeeded(Self.complete)
        #expect(!model.isPresented)
    }

    @Test func completedOnboardingStaysHiddenWhileNothingIsMissing() {
        let defaults = InMemorySettingsStore()
        defaults.set(true, forKey: OnboardingModel.completedKey)
        let model = OnboardingModel(defaults: defaults) {}
        model.presentIfNeeded(Self.complete)
        #expect(!model.isPresented)
        // Stellt sich später heraus, dass ein erforderlicher Schritt fehlt, erscheint es (einmal je Start).
        model.presentIfNeeded(Self.missingFullDiskAccess)
        #expect(model.isPresented)
    }

    @Test func forcedPresentationIgnoresTheChecklist() {
        let defaults = InMemorySettingsStore()
        defaults.set(true, forKey: OnboardingModel.completedKey)
        let model = OnboardingModel(defaults: defaults, forcesPresentation: true) {}
        model.presentIfNeeded(Self.complete)
        #expect(model.isPresented)
    }

    @Test func finishPersistsAndNotifies() {
        let defaults = InMemorySettingsStore()
        var finished = 0
        let model = OnboardingModel(defaults: defaults) { finished += 1 }
        model.present()
        model.finish()
        #expect(!model.isPresented && model.hasCompleted && finished == 1)
        #expect(defaults.bool(forKey: OnboardingModel.completedKey))
        #expect(OnboardingModel(defaults: defaults) {}.hasCompleted)
    }

    @Test func postponeDoesNotPersist() {
        let defaults = InMemorySettingsStore()
        let model = OnboardingModel(defaults: defaults) {}
        model.present()
        model.postpone()
        #expect(!model.isPresented && !model.hasCompleted)
        #expect(!defaults.bool(forKey: OnboardingModel.completedKey))
    }

    @Test func pendingUpdateDecisionPresentsOnceAfterCompletion() {
        let defaults = InMemorySettingsStore()
        defaults.set(true, forKey: OnboardingModel.completedKey)
        let model = OnboardingModel(defaults: defaults, needsUpdateDecision: { true }) {}
        model.presentIfNeeded(Self.complete)
        #expect(model.isPresented)
        model.postpone()
        model.presentIfNeeded(Self.complete)
        #expect(!model.isPresented)
    }

    @Test func decidedUpdatesDoNotPresent() {
        let defaults = InMemorySettingsStore()
        defaults.set(true, forKey: OnboardingModel.completedKey)
        let model = OnboardingModel(defaults: defaults, needsUpdateDecision: { false }) {}
        model.presentIfNeeded(Self.complete)
        #expect(!model.isPresented)
    }
}
