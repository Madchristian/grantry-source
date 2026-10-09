import Testing
@testable import ManagerKit

@MainActor
struct DockVisibilityModelTests {
    @Test func freshInstallationKeepsDockVisibleWhenStarted() {
        let settings = InMemorySettingsStore()
        var applied: [Bool] = []
        let model = DockVisibilityModel(defaults: settings) { applied.append($0); return true }
        #expect(model.showsDockIcon)
        model.applyCurrentVisibility()
        #expect(applied == [true])
    }

    @Test func changesApplyImmediatelyAndSurviveRestartInBothDirections() {
        let settings = InMemorySettingsStore()
        var applied: [Bool] = []
        let model = DockVisibilityModel(defaults: settings) { applied.append($0); return true }
        model.setShowsDockIcon(false)
        #expect(!model.showsDockIcon)
        #expect(applied == [false])
        let restarted = DockVisibilityModel(defaults: settings) { applied.append($0); return true }
        restarted.applyCurrentVisibility()
        #expect(!restarted.showsDockIcon)
        #expect(applied == [false, false])
        restarted.setShowsDockIcon(true)
        #expect(applied == [false, false, true])
        let next = DockVisibilityModel(defaults: settings) { applied.append($0); return true }
        next.applyCurrentVisibility()
        #expect(next.showsDockIcon)
        #expect(applied == [false, false, true, true])
    }

    @Test func rejectedPolicyChangeDoesNotPersistASettingThatWasNotApplied() {
        let settings = InMemorySettingsStore()
        let model = DockVisibilityModel(defaults: settings) { _ in false }
        model.setShowsDockIcon(false)
        #expect(model.showsDockIcon)
        #expect(settings.object(forKey: DockVisibilityModel.storageKey) == nil)
    }

    @Test func invalidStoredValueUsesVisibleDefault() {
        let settings = InMemorySettingsStore()
        settings.set("invalid", forKey: DockVisibilityModel.storageKey)
        let model = DockVisibilityModel(defaults: settings) { _ in true }
        #expect(model.showsDockIcon)
    }
}
