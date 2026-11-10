import Testing
@testable import ManagerKit

/// Der Takt gilt für Task-Manager und Menüleiste gemeinsam und übersteht einen Neustart (TM17, Entscheidung E2).
@MainActor
@Suite struct TaskManagerIntervalSettingTests {
    private let settings = InMemorySettingsStore()

    @Test func intervalIsRememberedAcrossLaunches() {
        let model = TaskManagerModel(sources: TaskManagerSources(), settings: settings)
        #expect(model.interval == .default)
        model.interval = .twoSeconds
        #expect(TaskManagerModel(sources: TaskManagerSources(), settings: settings).interval == .twoSeconds)
    }

    @Test func unknownStoredIntervalFallsBackToDefault() {
        settings.set("zehnSekunden", forKey: TaskManagerModel.intervalStorageKey)
        #expect(TaskManagerModel(sources: TaskManagerSources(), settings: settings).interval == .default)
    }

    @Test func withoutSettingsNothingIsStored() {
        let model = TaskManagerModel(sources: TaskManagerSources())
        model.interval = .fiveSeconds
        #expect(TaskManagerModel(sources: TaskManagerSources()).interval == .default)
    }
}
