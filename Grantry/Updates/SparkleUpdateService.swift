import AppKit
import ManagerKit
import Sparkle

/// Sparkle ist alleiniger Feed-Client, sobald ein gültiger Public Key konfiguriert ist.
/// Der eigene UserDriver zeigt keine zusätzlichen Fenster und lädt keine Release Notes vorab.
@MainActor
final class SparkleUpdateService: NSObject, UpdateInstalling, SPUUserDriver, SPUUpdaterDelegate {
    var onStatus: ((String?, String?) -> Void)?
    private lazy var updater: SPUUpdater = {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        updater.userAgentString = installed.userAgent
        updater.httpHeaders = ["Accept-Language": "*"]
        return updater
    }()
    private let installed: InstalledBuild
    private var started = false
    private let canInstall: () -> Bool
    private let canWrite: () -> Bool
    private var continuation: CheckedContinuation<AppcastItem?, any Error>?
    private var offered: AppcastItem?
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var ready: ((SPUUserUpdateChoice) -> Void)?
    private var cancel: (() -> Void)?
    private var installsAutomatically = false
    private var automaticRequest = false
    private var isDownloading = false
    private var isReady = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    static func configured(canInstall: @escaping () -> Bool) -> SparkleUpdateService? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: value)?.count == 32 else { return nil }
        return SparkleUpdateService(canInstall: canInstall)
    }

    init(installed: InstalledBuild = .current(), canInstall: @escaping () -> Bool, canWrite: @escaping () -> Bool = {
        FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.path)
            && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }) {
        self.installed = installed
        self.canInstall = canInstall
        self.canWrite = canWrite
        super.init()
    }

    func check() async throws -> AppcastItem? {
        guard continuation == nil else { throw UpdateInstallationError.busy }
        if isDownloading || isReady { return offered }
        if !started { try updater.start(); started = true }
        if let choice {
            self.choice = nil
            choice(.dismiss)
            // Sparkle beendet seinen bisherigen Dialog-Zyklus asynchron.
            for _ in 0..<200 where updater.sessionInProgress {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard updater.canCheckForUpdates else { throw UpdateInstallationError.busy }
        offered = nil
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            updater.checkForUpdates()
        }
    }

    func install(_ item: AppcastItem, automatically: Bool) {
        do {
            try UpdateInstallationPolicy.validateOffer(item, installed: installed)
            guard item == offered else {
                // Nach abgebrochenem Download ist Sparkles Zyklus beendet; ein neuer Knopf startet einen neuen Check.
                Task {
                    do {
                        if let refreshed = try await check() { install(refreshed, automatically: automatically) }
                    } catch { onStatus?(nil, readable(error)) }
                }
                return
            }
            if !automatically && !canInstall() { throw UpdateInstallationError.busy }
            guard canWrite() else { throw UpdateInstallationError.noWritePermission }
            automaticRequest = automatically
            if isReady {
                guard !automatically else { return }
                let reply = ready; ready = nil
                reply?(.install)
            } else if !isDownloading {
                // Das Herunterladen darf während eines Scans laufen. Erst beim Beenden wird der Scan gestoppt.
                let reply = choice; choice = nil
                isDownloading = true
                onStatus?("Update wird heruntergeladen …", nil)
                reply?(.install)
            }
        } catch {
            onStatus?(nil, error.localizedDescription)
        }
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        installsAutomatically = enabled
        if enabled { finishCancellationWaiters() }
        if !enabled && automaticRequest {
            cancel?()
            cancel = nil
            if let ready { self.ready = nil; ready(.skip) }
        }
    }

    func cancelCheck() {
        cancel?()
        cancel = nil
        finish(.failure(CancellationError()))
    }

    func prepareToTerminate() async {
        guard automaticRequest, !installsAutomatically, isDownloading else { return }
        // Während der Extraktion gibt es keinen Download-Abbruchhandler mehr. Erst Sparkles .skip abschließen,
        // sonst könnte „Automatisch aus“ + sofortiges Beenden die vorbereitete Version dennoch installieren.
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func finish(_ result: Result<AppcastItem?, any Error>) {
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }

    static func convert(_ item: SUAppcastItem) -> AppcastItem? {
        guard let url = item.fileURL, item.contentLength <= UInt64(Int.max) else { return nil }
        let properties = item.propertiesDictionary
        let enclosure = properties["enclosure"] as? [String: Any] ?? [:]
        return AppcastItem(version: item.displayVersionString, build: item.versionString, downloadURL: url,
            releaseNotesURL: item.releaseNotesURL, length: Int(item.contentLength),
            edSignature: enclosure["sparkle:edSignature"] as? String, sha256: enclosure["grantry:sha256"] as? String,
            minimumSystemVersion: item.minimumSystemVersion)
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        appcast.items.compactMap { item -> (SUAppcastItem, AppcastItem)? in
            guard let parsed = Self.convert(item), UpdateChecker.isApplicable(parsed, installed: installed)
            else { return nil }
            return (item, parsed)
        }.max { $0.1.build < $1.1.build }?.0 ?? SUAppcastItem.empty()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let parsed = Self.convert(item) else { throw UpdateInstallationError.invalidArchive }
        // Unsignierte historische Einträge bleiben als manueller Download erreichbar.
        // Die Signaturpflicht greift beim Installationsknopf und beim automatischen Download.
        guard UpdateChecker.isApplicable(parsed, installed: installed) else { throw UpdateInstallationError.downgrade }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).code == Int(SUError.noUpdateError.rawValue) { finish(.success(nil)); return }
        finish(.failure(error))
        onStatus?(nil, readable(error))
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { cancel = cancellation }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let parsed = Self.convert(item) else {
            reply(.dismiss)
            finish(.failure(UpdateInstallationError.invalidArchive))
            return
        }
        offer(parsed, stage: state.stage, reply: reply)
    }

    /// Eigener Dialogzustand ohne App-/Helper-Zugriff; auch hostlos prüfbar.
    func offer(_ item: AppcastItem, stage: SPUUserUpdateStage, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        offered = item
        if stage == .installing {
            isReady = true
            ready = reply
        } else {
            choice = reply
        }
        cancel = nil
        finish(.success(item))
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        finish(.success(nil)); acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        finish(.failure(error)); onStatus?(nil, readable(error)); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { cancel = cancellation }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { cancel = nil; onStatus?("Update wird geprüft …", nil) }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        isReady = true
        ready = reply
        if automaticRequest {
            if installsAutomatically {
                // Handler offen halten: Sparkle installiert beim regulären Beenden, ohne selbst zu beenden.
                onStatus?("Update bereit – wird beim nächsten Beenden installiert.", nil)
            } else {
                ready = nil
                reply(.skip)
                onStatus?(nil, nil)
            }
        } else if canInstall() {
            ready = nil
            reply(.install)
        } else {
            onStatus?("Update bereit.", UpdateInstallationError.busy.localizedDescription)
        }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        choice = nil; ready = nil; cancel = nil
        offered = nil; isDownloading = false; isReady = false; automaticRequest = false
        finishCancellationWaiters()
    }

    private func finishCancellationWaiters() {
        let waiters = cancellationWaiters; cancellationWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func readable(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.installationWriteNoPermissionError.rawValue) {
            return UpdateInstallationError.noWritePermission.localizedDescription
        }
        if nsError.domain == SUSparkleErrorDomain,
           nsError.code == Int(SUError.validationError.rawValue) || nsError.code == Int(SUError.signatureError.rawValue) {
            return UpdateInstallationError.invalidSignature.localizedDescription
        }
        if nsError.domain == NSURLErrorDomain { return "Keine Netzverbindung. Bitte später erneut versuchen." }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return readable(underlying) }
        return "Update fehlgeschlagen: \(error.localizedDescription) Die bisherige Version bleibt erhalten."
    }
}
