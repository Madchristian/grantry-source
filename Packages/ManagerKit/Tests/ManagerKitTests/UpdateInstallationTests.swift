import Foundation
import Testing
@testable import ManagerKit

@Suite struct UpdateInstallationTests {
    private let installed = InstalledBuild(info: ["CFBundleShortVersionString": "2026.10.4", "CFBundleVersion": "280"],
        systemVersion: SystemVersion(major: 27), architecture: "arm64")

    @Test func rejectsMissingMalformedSignatureAndDowngrade() throws {
        func item(signature: String? = Data(repeating: 0, count: 64).base64EncodedString(),
                  build: String = "281", version: String = "2026.10.5") throws -> AppcastItem {
            try #require(AppcastItem(version: version, build: build,
                downloadURL: URL(string: "https://grantry.cstrube.de/download/test.dmg")!,
                releaseNotesURL: nil, length: 123, edSignature: signature, sha256: nil))
        }
        try UpdateInstallationPolicy.validateOffer(item(), installed: installed)
        #expect(throws: UpdateInstallationError.invalidSignature) {
            try UpdateInstallationPolicy.validateOffer(item(signature: nil), installed: installed)
        }
        #expect(throws: UpdateInstallationError.invalidSignature) {
            try UpdateInstallationPolicy.validateOffer(item(signature: "invalid"), installed: installed)
        }
        for build in ["279", "280"] {
            #expect(throws: UpdateInstallationError.downgrade) {
                try UpdateInstallationPolicy.validateOffer(item(build: build), installed: installed)
            }
        }
        #expect(throws: UpdateInstallationError.downgrade) {
            try UpdateInstallationPolicy.validateOffer(item(build: "1000281"), installed: installed)
        }
    }

    @Test func acceptsNextDayAfterSameDaySuffixUsingTheBuildCounter() throws {
        let installed = InstalledBuild(info: ["CFBundleShortVersionString": "2026.10.192", "CFBundleVersion": "855"],
            systemVersion: SystemVersion(major: 27), architecture: "arm64")
        let next = try #require(AppcastItem(version: "2026.10.20", build: "859",
            downloadURL: URL(string: "https://grantry.cstrube.de/download/next.dmg")!, releaseNotesURL: nil,
            length: 123, edSignature: Data(repeating: 0, count: 64).base64EncodedString(), sha256: nil))
        try UpdateInstallationPolicy.validateOffer(next, installed: installed)
    }

    @Test func parserKeepsUnsignedHistoryAndSignatureMetadata() throws {
        let signature = Data(repeating: 0, count: 64).base64EncodedString()
        let unsigned = AppcastParserTests.item()
        let signed = unsigned.replacingOccurrences(of: "length=", with: "sparkle:edSignature=\"\(signature)\" length=")
        let items = try AppcastParser.items(from: AppcastParserTests.feed(signed, unsigned) + Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: 1\n-->\n".utf8))
        #expect(items.count == 2)
        #expect(items[0].edSignature == signature)
        #expect(items[0].length == 2_661_986)
        #expect(items[1].edSignature == nil)
    }

    @Test @MainActor func rejectsCleanupAndHelperActivity() {
        let lock = HelperActivityLock()
        #expect(UpdateInstallationPolicy.canInstall(isCleaning: false, isRemoving: false, helperActivity: lock))
        #expect(!UpdateInstallationPolicy.canInstall(isCleaning: true, isRemoving: false, helperActivity: lock))
        #expect(!UpdateInstallationPolicy.canInstall(isCleaning: false, isRemoving: true, helperActivity: lock))
        #expect(lock.begin(.action))
        #expect(!UpdateInstallationPolicy.canInstall(isCleaning: false, isRemoving: false, helperActivity: lock))
    }

    @Test func automaticInstallationDefaultsOff() {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        #expect(!preferences.installsAutomatically)
        preferences.installsAutomatically = true
        #expect(preferences.installsAutomatically)
    }
}

@MainActor
@Suite struct UpdateInstallerModelTests {
    private final class Installer: UpdateInstalling {
        var onStatus: ((String?, String?) -> Void)?
        var item: AppcastItem?
        var safetyError: String?
        var validation: (() async -> String?)?
        func verifyInstalledApplication() async -> String? {
            if let validation { return await validation() }
            return safetyError
        }
        var checks = 0
        var automaticSetting = false
        var installations: [Bool] = []
        func check() async throws -> AppcastItem? { checks += 1; return item }
        func install(_ item: AppcastItem, automatically: Bool) { installations.append(automatically) }
        func setAutomaticInstallation(_ enabled: Bool) { automaticSetting = enabled }
        func cancelCheck() {}
    }

    private struct NoNetwork: FeedFetching {
        func fetch(_ url: URL, userAgent: String) async throws -> Data {
            Issue.record("Zweiter Feed-Abruf über den bisherigen Checker")
            throw URLError(.notConnectedToInternet)
        }
    }

    @Test func failedIdentityCheckDisablesAutomaticInstallationAndKeepsWarning() async {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        preferences.installsAutomatically = true
        let installer = Installer()
        installer.safetyError = "Fremdes Signaturteam"
        var warnings: [String] = []
        let model = UpdateModel(preferences: preferences, notifier: RecordingNotifier(),
            checksAutomatically: false, installer: installer,
            onInstallationIdentityFailure: { warnings.append($0) }, openURL: { _ in })
        await model.verifyInstallation()
        await model.verifyInstallation()
        #expect(warnings == ["Fremdes Signaturteam"])
        #expect(!model.installsAutomatically)
        #expect(!preferences.installsAutomatically)
        #expect(!installer.automaticSetting)
        #expect(model.installationError == installer.safetyError)
        model.setAutomaticInstallation(true)
        installer.onStatus?("Prüfung abgeschlossen", nil)
        #expect(!model.installsAutomatically)
        #expect(model.installationError == installer.safetyError)
    }

    @Test func automaticInstallationWaitsForIdentityVerification() async {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        preferences.consent = .enabled
        preferences.installsAutomatically = true
        let installer = Installer()
        var pending: CheckedContinuation<String?, Never>?
        installer.validation = { await withCheckedContinuation { pending = $0 } }
        let model = UpdateModel(preferences: preferences, notifier: RecordingNotifier(),
            checksAutomatically: false, installer: installer, openURL: { _ in })
        while pending == nil { await Task.yield() }
        model.setAutomaticInstallation(true)
        #expect(!installer.automaticSetting)
        pending?.resume(returning: nil)
        await model.verifyInstallation()
        #expect(installer.automaticSetting)
        #expect(model.installationIdentityError == nil)
    }

    @Test func disablingChecksDuringIdentityVerificationDoesNotFetchTheFeed() async {
        let preferences = UpdatePreferences(store: InMemorySettingsStore())
        preferences.consent = .enabled
        let installer = Installer()
        var pending: CheckedContinuation<String?, Never>?
        installer.validation = { await withCheckedContinuation { pending = $0 } }
        let model = UpdateModel(preferences: preferences, notifier: RecordingNotifier(),
            checksAutomatically: true, installer: installer, openURL: { _ in })
        let checking = Task { await model.checkIfDue() }
        while pending == nil || model.runningCheck == nil { await Task.yield() }
        model.setEnabled(false)
        pending?.resume(returning: nil)
        await checking.value
        #expect(installer.checks == 0)
    }

    @Test func usesOnlySparkleFeedAndOptInInstallation() async throws {
        let store = InMemorySettingsStore()
        let preferences = UpdatePreferences(store: store)
        preferences.consent = .enabled
        let installer = Installer()
        let items = try AppcastParser.items(from: AppcastParserTests.feed(AppcastParserTests.item()))
        installer.item = try #require(items.first)
        let model = UpdateModel(preferences: preferences,
            checker: UpdateChecker(fetcher: NoNetwork()), notifier: RecordingNotifier(),
            checksAutomatically: false, installer: installer, openURL: { _ in Issue.record("Browser statt Installer") })
        await model.verifyInstallation()
        _ = await model.checkNow()
        #expect(installer.checks == 1)
        #expect(installer.installations.isEmpty)
        #expect(model.supportsInstallation)
        #expect(model.downloadButtonTitle == "Installieren und neu starten")
        model.openDownload(try #require(installer.item))
        #expect(installer.installations == [false])
        model.setAutomaticInstallation(true)
        #expect(installer.automaticSetting)
        #expect(installer.installations == [false, true])
        installer.onStatus?(nil, "Signatur ungültig")
        #expect(model.installationError == "Signatur ungültig")
        model.setEnabled(false)
        #expect(!installer.automaticSetting)
        _ = await model.checkNow()
        #expect(installer.installations == [false, true])
    }
}
