import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@MainActor
@Suite struct UpdateModelTests {
    /// Liefert `result`, auf Wunsch erst nach `release()`; zählt die Abrufe.
    private final class GatedFetcher: FeedFetching {
        private struct State {
            var fetchCount = 0
            var isReleased: Bool
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let result: Result<Data, any Error>
        private let state: Mutex<State>

        init(_ result: Result<Data, any Error>, gated: Bool = false) {
            self.result = result
            state = Mutex(State(isReleased: !gated))
        }

        var fetchCount: Int { state.withLock { $0.fetchCount } }

        func release() {
            let waiters = state.withLock { state in
                state.isReleased = true
                defer { state.waiters = [] }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }

        func fetch(_ url: URL, userAgent: String) async throws -> Data {
            await withCheckedContinuation { continuation in
                let mustWait = state.withLock { state in
                    state.fetchCount += 1
                    if !state.isReleased { state.waiters.append(continuation) }
                    return !state.isReleased
                }
                if !mustWait { continuation.resume() }
            }
            return try result.get()
        }
    }

    private struct Offline: Error {}

    private static let installed = InstalledBuild(
        info: ["CFBundleShortVersionString": "2026.10.4", "CFBundleVersion": "276"],
        systemVersion: SystemVersion(major: 27), architecture: "arm64"
    )
    private static let newerFeed = AppcastParserTests.feed(AppcastParserTests.item(version: "2026.10.5", build: "280"))
    private static let currentFeed = AppcastParserTests.feed(AppcastParserTests.item(version: "2026.10.4", build: "276"))

    private let store = InMemorySettingsStore()
    private let notifier = RecordingNotifier()

    private func model(
        _ fetcher: GatedFetcher, consent: UpdateConsent? = .enabled, checksAutomatically: Bool = true
    ) -> UpdateModel {
        let preferences = UpdatePreferences(store: store)
        if let consent { preferences.consent = consent }
        return UpdateModel(
            preferences: preferences,
            checker: UpdateChecker(feedURL: UpdateFeed.url, fetcher: fetcher, installed: Self.installed),
            notifier: notifier, checksAutomatically: checksAutomatically, openURL: { _ in }
        )
    }

    /// Wartet, bis `condition` gilt (andere Aufgaben auf dem Main Actor laufen dazwischen weiter).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func automaticCheckNotifiesOncePerVersion() async {
        let model = model(GatedFetcher(.success(Self.newerFeed)))
        await model.checkIfDue()
        #expect(model.availableUpdate?.build == 280)
        #expect(notifier.all.map(\.destination) == [.update])
        #expect(notifier.all.first?.body == "Grantry 2026.10.5 ist verfügbar.")

        UpdatePreferences(store: store).lastSuccessfulCheck = nil
        await model.checkIfDue()
        #expect(notifier.all.count == 1)
    }

    @Test func manualCheckDoesNotNotifyButCountsAsNotified() async {
        let model = model(GatedFetcher(.success(Self.newerFeed)))
        let outcome = await model.checkNow()
        #expect(outcome == .available(model.availableUpdate!))
        #expect(model.lastOutcome == outcome)
        #expect(notifier.all.isEmpty)
        #expect(UpdatePreferences(store: store).lastNotifiedBuild == 280)

        UpdatePreferences(store: store).lastSuccessfulCheck = nil
        await model.checkIfDue()
        #expect(notifier.all.isEmpty)
    }

    @Test func outcomeIsUpToDateWithoutNewerVersion() async {
        let model = model(GatedFetcher(.success(Self.currentFeed)))
        let outcome = await model.checkNow()
        #expect(outcome == .upToDate("2026.10.4"))
        #expect(outcome?.text == "Grantry ist aktuell (2026.10.4).")
        #expect(model.lastCheck != nil)
    }

    @Test func outcomeIsFailedWhenUnreachable() async {
        let model = model(GatedFetcher(.failure(Offline())))
        let outcome = await model.checkNow()
        guard case .failed(let reason)? = outcome else {
            Issue.record("erwartet .failed, erhalten \(String(describing: outcome))")
            return
        }
        #expect(outcome?.text == "Update-Prüfung fehlgeschlagen: \(reason)")
        #expect(model.lastCheck == nil)
    }

    @Test func cancellationYieldsNoOutcome() async {
        let model = model(GatedFetcher(.failure(URLError(.cancelled))))
        #expect(await model.checkNow() == nil)
        #expect(model.lastOutcome == nil)
    }

    @Test func onboardingChoiceMirrorsConsent() {
        #expect(model(GatedFetcher(.success(Self.currentFeed)), consent: nil).onboardingChoice)
        #expect(model(GatedFetcher(.success(Self.currentFeed)), consent: .enabled).onboardingChoice)
        let disabled = model(GatedFetcher(.success(Self.currentFeed)), consent: .disabled)
        #expect(!disabled.onboardingChoice)
        disabled.setEnabled(true)
        #expect(disabled.onboardingChoice && disabled.isEnabled)
        disabled.setEnabled(false)
        #expect(!disabled.onboardingChoice && !disabled.isEnabled)
    }

    @Test func neverChecksAutomaticallyWithoutConsent() async {
        for consent in [UpdateConsent.undecided, .disabled] {
            let fetcher = GatedFetcher(.success(Self.newerFeed))
            await model(fetcher, consent: consent).checkIfDue()
            #expect(fetcher.fetchCount == 0)
        }
        let fetcher = GatedFetcher(.success(Self.newerFeed))
        await model(fetcher, checksAutomatically: false).checkIfDue()
        #expect(fetcher.fetchCount == 0)
    }

    @Test func concurrentChecksShareOneFetch() async {
        let fetcher = GatedFetcher(.success(Self.newerFeed), gated: true)
        let model = model(fetcher)
        let manual = Task { await model.checkNow() }
        let automatic = Task { await model.checkIfDue() }
        let second = Task { await model.checkNow() }
        await waitUntil { fetcher.fetchCount == 1 }
        #expect(model.isChecking)
        fetcher.release()
        let first = await manual.value
        await automatic.value
        #expect(await second.value == first)
        #expect(fetcher.fetchCount == 1)
        #expect(!model.isChecking)
    }

    @Test func disablingCancelsARunningAutomaticCheck() async {
        let fetcher = GatedFetcher(.success(Self.newerFeed), gated: true)
        let model = model(fetcher)
        let automatic = Task { await model.checkIfDue() }
        await waitUntil { fetcher.fetchCount == 1 }
        model.setEnabled(false)
        #expect(!model.isChecking)
        fetcher.release()
        await automatic.value
        #expect(notifier.all.isEmpty)
        #expect(model.availableUpdate == nil)
        #expect(UpdatePreferences(store: store).lastSuccessfulCheck == nil)
        #expect(model.lastCheck == nil)
    }

    @Test func stopCancelsARunningAutomaticCheck() async throws {
        let fetcher = GatedFetcher(.success(Self.newerFeed), gated: true)
        let model = model(fetcher)
        model.start()
        await waitUntil { fetcher.fetchCount == 1 }
        let running = try #require(model.runningCheck)
        #expect(running.isAutomatic)
        model.stop()
        #expect(model.runningCheck == nil && !model.isChecking)
        fetcher.release()
        await #expect(throws: CancellationError.self) { try await running.task.value }
        #expect(notifier.all.isEmpty)
        #expect(model.availableUpdate == nil)
        #expect(model.lastCheck == nil)
        #expect(UpdatePreferences(store: store).lastSuccessfulCheck == nil)
    }

    @Test func manualCheckJoinsARunningAutomaticCheck() async throws {
        let fetcher = GatedFetcher(.success(Self.newerFeed), gated: true)
        let model = model(fetcher)
        let automatic = Task { await model.checkIfDue() }
        await waitUntil { fetcher.fetchCount == 1 }
        let running = try #require(model.runningCheck)
        let manual = Task { await model.checkNow() }
        // Der manuelle Aufrufer hat sich angehängt, sobald die Prüfung nicht mehr abbrechbar ist.
        await waitUntil { model.runningCheck?.isAutomatic == false }
        #expect(model.runningCheck?.isAutomatic == false)
        fetcher.release()
        let shared = try await running.task.value
        await automatic.value
        let outcome = await manual.value
        let item = try #require(shared)
        #expect(outcome == .available(item))
        #expect(model.availableUpdate == item)
        #expect(fetcher.fetchCount == 1)
        #expect(notifier.all.count == 1)
    }

    @Test func openingUsesTheItemLinks() async throws {
        var opened: [URL] = []
        let preferences = UpdatePreferences(store: store)
        let model = UpdateModel(
            preferences: preferences,
            checker: UpdateChecker(
                feedURL: UpdateFeed.url, fetcher: GatedFetcher(.success(Self.newerFeed)), installed: Self.installed
            ),
            notifier: notifier, checksAutomatically: false, openURL: { opened.append($0) }
        )
        await model.checkNow()
        let item = try #require(model.availableUpdate)
        #expect(item.hasReleaseNotes)
        model.openDownload(item)
        model.openReleaseNotes(item)
        #expect(opened == [item.downloadURL, try #require(item.releaseNotesURL)])
    }
}
