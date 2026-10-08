import AppKit
import ManagerKit
import Observation

// Nebenläufigkeit: Verlässt sich auf die Semantik von Swift 6.0 – nonisolated async-Aufrufe in ManagerKit
// (`HelperManager.state()` usw.) laufen außerhalb des Main Actors. Wird
// `NonisolatedNonsendingByDefault` aktiviert, liefen sie auf dem Actor des Aufrufers; dann brauchen die
// Einstiegspunkte im Kit `@concurrent`.

/// Einrichtung der App (Spec §6, Onboarding): Festplattenvollzugriff, privilegierter Helper, Benachrichtigungen und
/// „Beim Anmelden starten“. Prüft den Zustand, führt die angebotenen Aktionen aus und liefert die Checkliste für
/// Onboarding, Einstellungen und das Banner der Übersicht; Scans übernimmt `AppModel`.
@MainActor
@Observable
final class PrerequisitesModel {
    /// `true`, wenn die System-TCC-Datenbank lesbar ist; `nil`, solange die Prüfung läuft.
    private(set) var fullDiskAccess: Bool?
    /// Zustand des Helpers; `nil`, solange er ermittelt wird (bis zur Erreichbarkeitsfrist des `HelperClient`, 5 s).
    private(set) var helperState: HelperState?
    private(set) var notifications: NotificationAuthorization?
    private(set) var launchAtLogin: LoginItemStatus?
    /// `true`, solange Voraussetzungen geprüft oder der Helper (neu) registriert wird.
    private(set) var isUpdatingPrerequisites = false
    /// Lesbare Meldung des zuletzt fehlgeschlagenen Helper-Vorgangs.
    private(set) var helperActionError: String?
    /// Grund und Abhilfe, wenn das Erneuern der Registrierung nach einem App-Update endgültig scheiterte
    /// (`HelperRenewalError`). Anders als `helperActionError` übersteht sie spätere Prüfungen und gilt, bis der Helper
    /// wieder registriert ist.
    private(set) var helperRenewalFailure: String?
    /// Lesbare Meldung, wenn „Beim Anmelden starten“ nicht geändert werden konnte.
    private(set) var launchAtLoginError: String?
    /// `true`, solange „Beim Anmelden starten“ geändert wird.
    private(set) var isChangingLaunchAtLogin = false

    private let helperManager: HelperManager
    private let notifier: UNUserNotificationCenterNotifier
    private let loginItem: LaunchAtLogin
    private let fullDiskAccessProbe = FullDiskAccessProbe()
    /// Schließt Helper-Installation und Aktionen gegenseitig aus (geteilt mit dem `ActionRunner`).
    private let helperActivity: HelperActivityLock
    /// Bricht die laufende Aktion ab (`ActionRunner.abandonRunningAction()`), damit ein nicht erreichbarer Helper neu
    /// installiert werden kann.
    private let abandonRunningAction: @MainActor () async -> Void
    /// Wird aufgerufen, wenn der Helper oder der Festplattenvollzugriff verfügbar wird, nachdem er zuvor nachweislich
    /// fehlte (z. B. nach der Genehmigung) – etwa für einen Scan, der die neuen Quellen einbezieht.
    private let onPrerequisiteBecameAvailable: @MainActor () -> Void
    /// Zuletzt ermittelter Helper-Zustand; anders als `helperState` nie „wird ermittelt“.
    private var lastResolvedHelperState: HelperState?

    /// Abstand der Prüfungen auf Festplattenvollzugriff, solange die Checkliste sichtbar ist (Spec §6).
    private static let fullDiskAccessPollInterval: Duration = .seconds(2)
    /// Abstand, in dem eine wartende Helper-Wartung prüft, ob die laufende Prüfung beendet ist.
    private static let busyPollInterval: Duration = .milliseconds(100)

    /// - Parameters:
    ///   - helperClient: gemeinsame XPC-Verbindung zum Helper (dieselbe wie die der BTM-Quelle).
    ///   - helperActivity: dieselbe Sperre wie die des `ActionRunner`.
    ///   - abandonRunningAction: bricht die laufende Aktion des `ActionRunner` ab.
    ///   - afterHelperRegistration: nach jeder (Neu-)Registrierung des Helpers (`HelperManager`), z. B.
    ///     `ListenerHelperSchedule.reset()`, damit der nächste Teilscan den Helper sofort fragt.
    ///   - onPrerequisiteBecameAvailable: z. B. ein Scan, damit die neuen Quellen sofort ihre Baseline erhalten.
    init(
        helperClient: HelperClient,
        helperActivity: HelperActivityLock,
        abandonRunningAction: @escaping @MainActor () async -> Void,
        notifier: UNUserNotificationCenterNotifier = UNUserNotificationCenterNotifier(),
        loginItem: LaunchAtLogin = LaunchAtLogin(),
        afterHelperRegistration: @escaping @Sendable () -> Void = {},
        onPrerequisiteBecameAvailable: @escaping @MainActor () -> Void
    ) {
        helperManager = HelperManager(client: helperClient, afterRegistration: afterHelperRegistration)
        self.helperActivity = helperActivity
        self.abandonRunningAction = abandonRunningAction
        self.notifier = notifier
        self.loginItem = loginItem
        self.onPrerequisiteBecameAvailable = onPrerequisiteBecameAvailable
    }

    /// Checkliste zum aktuellen Zustand (Onboarding, Einstellungen).
    var checklist: SetupChecklist {
        SetupChecklist(status(helper: helperState))
    }

    /// `true`, wenn Festplattenvollzugriff nachweislich fehlt (Banner und Menüleiste verlinken die Einstellungen).
    var isFullDiskAccessMissing: Bool { fullDiskAccess == false }

    /// Text des Banners in der Übersicht; `nil`, solange nichts Erforderliches nachweislich fehlt. Während einer
    /// erneuten Prüfung gilt der zuletzt ermittelte Helper-Zustand, damit das Banner nicht flackert.
    var missingPrerequisitesText: String? {
        guard let text = settledChecklist.bannerText else { return nil }
        guard helperRenewalFailure != nil else { return text }
        return "\(text) Nach dem Update ließ sich der Helper nicht automatisch neu registrieren – in der Einrichtung "
            + "„Installieren“ wählen."
    }

    /// Nachweislich fehlende erforderliche Schritte – wie das Banner mit dem zuletzt ermittelten Helper-Zustand; für den
    /// nächsten Schritt einer Abdeckungslücke (`AreaCoverage.nextStep(missingSetupSteps:)`, #142).
    var missingSetupSteps: Set<SetupStep> {
        Set(settledChecklist.missingRequired.map(\.step))
    }

    /// Checkliste, die während einer erneuten Prüfung den zuletzt ermittelten Helper-Zustand nutzt, damit Banner und
    /// Hinweise nicht flackern.
    private var settledChecklist: SetupChecklist {
        SetupChecklist(status(helper: helperState ?? lastResolvedHelperState))
    }

    /// Fehlermeldung unter der Checkliste: zuletzt gescheiterte Aktion, sonst die gescheiterte Erneuerung nach einem
    /// Update, sonst „Beim Anmelden starten“.
    var setupErrorText: String? {
        helperActionError ?? helperRenewalFailure ?? launchAtLoginError
    }

    /// Prüft alle Schritte erneut. `showsProgress` setzt den Helper währenddessen auf „wird ermittelt“; ohne bleibt
    /// der bisherige Zustand sichtbar (z. B. bei der Rückkehr aus den Systemeinstellungen).
    func refresh(showsProgress: Bool = true) async {
        async let notifications = notifier.authorizationStatus()
        launchAtLogin = loginItem.status
        await updatePrerequisites(showsProgress: showsProgress) {
            async let fullDiskAccess = self.fullDiskAccessProbe.hasFullDiskAccess()
            async let helperState = self.helperManager.state()
            self.updateFullDiskAccess(await fullDiskAccess)
            return await helperState
        }
        self.notifications = await notifications
    }

    /// Beim App-Start: Wurde das App-Bundle seit der letzten Registrierung des Helpers ausgetauscht (anderer Build),
    /// registriert es ihn neu (`HelperManager.registrationRenewal`, `renewRegistration()`), damit launchd ihn wieder
    /// startet. Die Entscheidung samt Grund, Dienststatus, registriertem und laufendem Build wird immer als `notice`
    /// protokolliert (`HelperManager.assessRegistrationRenewalAtLaunch()`), auch ohne Erneuerung. Ohne Dialog;
    /// verlangt das System danach eine Genehmigung, steht der Helper auf „Wartet auf Genehmigung“ und die Einrichtung
    /// führt dorthin. Scheitert es endgültig, steht der Helper auf „Nicht installiert“ und `helperRenewalFailure` nennt
    /// Grund und Abhilfe. Läuft gerade eine Prüfung (z. B. die des Fensters beim Start), wartet die Erneuerung darauf,
    /// statt zu entfallen. Liefert `true`, wenn neu registriert wurde.
    @discardableResult
    func renewHelperRegistrationIfNeeded() async -> Bool {
        guard helperManager.assessRegistrationRenewalAtLaunch().shouldRenew else { return false }
        await maintainHelper(waitsWhileBusy: true) { try await self.helperManager.renewRegistration() }
        return true
    }

    /// Nach einem Scan: prüft die Einrichtung erneut (ohne Ladezustand), wenn etwas fehlt oder eine davon abhängige
    /// Quelle ausfiel (`SetupChecklist.shouldRecheck(after:)`) – so meldet auch die Menüleiste ohne offenes Fenster
    /// einen verlorenen Festplattenvollzugriff.
    func recheck(after snapshot: Snapshot) async {
        guard !isUpdatingPrerequisites, settledChecklist.shouldRecheck(after: snapshot) else { return }
        await refresh(showsProgress: false)
    }

    /// Prüft alle 2 s, ob Festplattenvollzugriff erteilt wurde, bis er es ist oder die Aufgabe abgebrochen wird.
    func pollFullDiskAccess() async {
        while fullDiskAccess != true {
            do {
                try await Task.sleep(for: Self.fullDiskAccessPollInterval)
            } catch {
                return
            }
            updateFullDiskAccess(await fullDiskAccessProbe.hasFullDiskAccess())
        }
    }

    /// Ob die Aktion gerade angeboten werden kann: nicht während einer Prüfung, und den Helper (neu) installieren
    /// nicht, solange eine Aktion läuft – außer, der Helper ist nicht erreichbar; dann bricht „Neu installieren“ die
    /// Aktion ab (`HelperActivityLock.maintenanceAccess(helperState:)`).
    func canPerform(_ action: SetupChecklist.Action) -> Bool {
        switch action {
        case .helper(.install), .helper(.reinstall): !isUpdatingPrerequisites && maintenanceAccess != .blocked
        default: !isUpdatingPrerequisites
        }
    }

    private var maintenanceAccess: HelperActivityLock.MaintenanceAccess {
        helperActivity.maintenanceAccess(helperState: helperState ?? lastResolvedHelperState)
    }

    /// Führt die zu einem Schritt angebotene Aktion aus.
    func perform(_ action: SetupChecklist.Action) async {
        switch action {
        case .openFullDiskAccessSettings: open(FullDiskAccessProbe.settingsURL)
        case .helper(.install): await maintainHelper { try await self.helperManager.register() }
        case .helper(.approve): HelperManager.openApprovalSettings()
        case .helper(.reinstall): await maintainHelper { try await self.helperManager.reinstall() }
        case .requestNotifications:
            _ = await notifier.requestAuthorization()
            notifications = await notifier.authorizationStatus()
        case .openNotificationSettings: open(NotificationAuthorization.settingsURL)
        case .openLoginItemSettings: LaunchAtLogin.openSettings()
        }
    }

    /// Registriert die App als Login-Item oder hebt die Registrierung auf; während einer Änderung wirkungslos.
    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !isChangingLaunchAtLogin else { return }
        isChangingLaunchAtLogin = true
        defer { isChangingLaunchAtLogin = false }
        launchAtLoginError = nil
        do {
            launchAtLogin = try await loginItem.setEnabled(enabled)
        } catch {
            launchAtLoginError = error.readableDescription
            launchAtLogin = loginItem.status
        }
    }

    private func status(helper: HelperState?) -> SetupStatus {
        SetupStatus(
            fullDiskAccess: fullDiskAccess, helper: helper, notifications: notifications, launchAtLogin: launchAtLogin
        )
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Übernimmt das Ergebnis der Probe; meldet den Wechsel von „fehlt“ zu „erteilt“.
    private func updateFullDiskAccess(_ granted: Bool) {
        let wasMissing = fullDiskAccess == false
        fullDiskAccess = granted
        if granted, wasMissing { onPrerequisiteBecameAvailable() }
    }

    /// Installiert den Helper (neu), sofern gerade keine Aktion läuft – hängt sie am nicht erreichbaren Helper, wird sie
    /// zuvor abgebrochen. Aktionen warten währenddessen.
    private func maintainHelper(
        waitsWhileBusy: Bool = false,
        _ operation: @escaping () async throws -> HelperState
    ) async {
        if maintenanceAccess == .afterAbandoningAction { await abandonRunningAction() }
        await helperActivity.perform(.helperMaintenance) {
            await updatePrerequisites(waitsWhileBusy: waitsWhileBusy, operation)
        }
    }

    /// Setzt den Helper-Zustand (mit `showsProgress`) auf „wird ermittelt“, führt `operation` aus und übernimmt deren
    /// Ergebnis. Fehler bleiben als `helperActionError` sichtbar – eine gescheiterte Erneuerung nach einem Update
    /// (`HelperRenewalError`) als `helperRenewalFailure`; der Zustand wird dann neu ermittelt. Läuft bereits eine
    /// Prüfung, entfällt der Aufruf – mit `waitsWhileBusy` wartet er stattdessen darauf.
    private func updatePrerequisites(
        showsProgress: Bool = true,
        waitsWhileBusy: Bool = false,
        _ operation: () async throws -> HelperState
    ) async {
        while isUpdatingPrerequisites {
            guard waitsWhileBusy else { return }
            do {
                try await Task.sleep(for: Self.busyPollInterval)
            } catch {
                return
            }
        }
        isUpdatingPrerequisites = true
        defer { isUpdatingPrerequisites = false }
        helperActionError = nil
        if showsProgress { helperState = nil }
        let resolved: HelperState
        do {
            resolved = try await operation()
        } catch let error as HelperRenewalError {
            helperRenewalFailure = error.readableDescription
            resolved = await helperManager.state()
        } catch {
            helperActionError = error.readableDescription
            resolved = await helperManager.state()
        }
        if resolved == .ready || resolved == .awaitingApproval { helperRenewalFailure = nil }
        helperState = resolved
        let wasReady = lastResolvedHelperState.map { $0 == .ready }
        lastResolvedHelperState = resolved
        if resolved == .ready, wasReady == false {
            onPrerequisiteBecameAvailable()
        }
    }
}
