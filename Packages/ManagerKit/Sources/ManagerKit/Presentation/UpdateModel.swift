import Foundation
import Observation
import os

/// Update-Hinweis (Spec Update-Hinweis §4): prüft mit Zustimmung stündlich, ob eine Prüfung fällig ist (alle 24 h),
/// hält eine gefundene Version bereit, meldet jede Version einmal und öffnet Download und Release Notes über
/// `openURL`. Installiert wird nichts. Es läuft höchstens eine Prüfung; weitere Aufrufer warten auf dieselbe.
@MainActor
@Observable
public final class UpdateModel {
    /// Ergebnis einer manuellen Prüfung.
    public enum Outcome: Equatable, Sendable {
        case available(AppcastItem)
        case upToDate(String)
        case failed(String)

        public var text: String {
            switch self {
            case .available(let item): item.availabilityText
            case .upToDate(let version): UpdateTexts.upToDate(version)
            case .failed(let reason): UpdateTexts.failed(reason)
            }
        }
    }

    public private(set) var availableUpdate: AppcastItem?
    public private(set) var consent: UpdateConsent
    public private(set) var lastCheck: Date?
    public private(set) var isChecking = false
    /// Ergebnis der letzten manuellen Prüfung (Einstellungen).
    public private(set) var lastOutcome: Outcome?
    /// Auswahl im Onboarding; gespeichert erst mit `commitOnboardingChoice()`. Spiegelt die gespeicherte Zustimmung
    /// (unentschieden: an), damit ein erneut geöffnetes Onboarding eine abgeschaltete Prüfung nicht wieder einschaltet.
    public var onboardingChoice: Bool

    /// Die laufende Prüfung; `isAutomatic`, solange nur automatische Aufrufer auf sie warten (dann abbrechbar).
    private struct RunningCheck {
        let id = UUID()
        let task: Task<AppcastItem?, any Error>
        var isAutomatic: Bool
    }

    @ObservationIgnored private let preferences: UpdatePreferences
    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let notifier: any UserNotifying
    @ObservationIgnored private let checksAutomatically: Bool
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var running: RunningCheck?

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "updates")
    /// Wie oft nachgesehen wird, ob eine Prüfung fällig ist (wirkt auch nach dem Aufwachen).
    private static let pollInterval: Duration = .seconds(60 * 60)

    /// - Parameters:
    ///   - checksAutomatically: `false` in Debug-Builds ohne Testfeed; manuelle Prüfungen gehen immer.
    ///   - openURL: öffnet Download und Release Notes (in der App im Browser).
    public init(
        preferences: UpdatePreferences = UpdatePreferences(),
        checker: UpdateChecker = UpdateChecker(),
        notifier: any UserNotifying = UNUserNotificationCenterNotifier(),
        checksAutomatically: Bool,
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        self.preferences = preferences
        self.checker = checker
        self.notifier = notifier
        self.checksAutomatically = checksAutomatically
        self.openURL = openURL
        consent = preferences.consent
        onboardingChoice = preferences.consent != .disabled
        lastCheck = preferences.lastSuccessfulCheck
    }

    /// Über die Update-Prüfung ist noch nicht entschieden (Onboarding erscheint dann einmal je Start).
    public var isDecisionPending: Bool { consent == .undecided }

    public var isEnabled: Bool { consent == .enabled }

    public var installedVersion: String { checker.installed.version }

    /// Speichert die Zustimmung; Abschalten bricht eine laufende automatische Prüfung ab (danach keine Meldung mehr).
    public func setEnabled(_ enabled: Bool) {
        preferences.consent = enabled ? .enabled : .disabled
        consent = preferences.consent
        onboardingChoice = enabled
        if enabled {
            Task { await checkIfDue() }
        } else {
            cancelAutomaticCheck()
        }
    }

    /// Übernimmt die Auswahl aus dem Onboarding („Fertig“).
    public func commitOnboardingChoice() {
        setEnabled(onboardingChoice)
    }

    public func start() {
        guard checksAutomatically, schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkIfDue()
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
            }
        }
    }

    /// Beendet den Prüftakt und bricht eine laufende automatische Prüfung ab.
    public func stop() {
        schedule?.cancel()
        schedule = nil
        cancelAutomaticCheck()
    }

    /// Manuelle Prüfung, unabhängig von der Zustimmung; `nil`, wenn sie abgebrochen wurde (kein Ergebnis anzuzeigen).
    /// Das Ergebnis wird angezeigt, daher ohne Systembenachrichtigung; eine gefundene Version gilt trotzdem als gemeldet.
    @discardableResult
    public func checkNow() async -> Outcome? {
        let outcome: Outcome
        do {
            outcome = try await check(automatic: false).map(Outcome.available) ?? .upToDate(installedVersion)
        } catch is CancellationError {
            return nil
        } catch {
            outcome = .failed(error.readableDescription)
        }
        lastOutcome = outcome
        return outcome
    }

    public func openDownload(_ item: AppcastItem) {
        openURL(item.downloadURL)
    }

    public func openReleaseNotes(_ item: AppcastItem) {
        guard let url = item.releaseNotesURL else { return }
        openURL(url)
    }

    /// Automatische Prüfung, wenn erlaubt und fällig; Fehler nur ins Log, ein Abbruch gar nicht.
    func checkIfDue() async {
        guard checksAutomatically, preferences.isCheckDue(now: .now) else { return }
        do {
            try await check(automatic: true)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.notice("Automatische Update-Prüfung gescheitert: \(error.readableDescription, privacy: .public)")
        }
    }

    /// Startet eine Prüfung oder wartet auf die laufende. Ein manueller Aufrufer macht die laufende unabbrechbar.
    @discardableResult
    private func check(automatic: Bool) async throws -> AppcastItem? {
        if let current = running {
            if !automatic { running?.isAutomatic = false }
            return try await current.task.value
        }
        let task = Task { try await self.performCheck(postsNotification: automatic) }
        let check = RunningCheck(task: task, isAutomatic: automatic)
        running = check
        isChecking = true
        defer {
            if running?.id == check.id {
                running = nil
                isChecking = false
            }
        }
        return try await task.value
    }

    /// Die laufende Prüfung und ob sie noch abbrechbar ist – damit Tests auf ihr Ende warten können.
    var runningCheck: (task: Task<AppcastItem?, any Error>, isAutomatic: Bool)? {
        running.map { ($0.task, $0.isAutomatic) }
    }

    private func cancelAutomaticCheck() {
        guard let current = running, current.isAutomatic else { return }
        current.task.cancel()
        running = nil
        isChecking = false
    }

    /// Prüft, merkt sich den Zeitpunkt und vermerkt eine neue Version als gemeldet (jede Version einmal).
    /// - Parameter postsNotification: Beim ersten Fund einer Version eine Systembenachrichtigung zeigen (automatische
    ///   Prüfung); `false` bei der manuellen Prüfung, die ihr Ergebnis selbst anzeigt.
    private func performCheck(postsNotification: Bool) async throws -> AppcastItem? {
        let found = try await checker.check()
        try Task.checkCancellation()
        let now = Date.now
        preferences.lastSuccessfulCheck = now
        lastCheck = now
        availableUpdate = found
        if let found, preferences.claimNotification(for: found), postsNotification {
            await notifier.post(
                title: UpdateTexts.availableTitle, body: found.availabilityText,
                identifier: "update-\(found.build)", destination: .update
            )
        }
        return found
    }
}
