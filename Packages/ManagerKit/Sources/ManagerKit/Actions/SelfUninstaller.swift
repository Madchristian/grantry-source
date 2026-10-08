import Foundation
import GrantryShared
import ServiceManagement

/// Was „Grantry deinstallieren …“ entfernt (#115): die gewählten Funde der Reste-Suche für Grantry selbst (App-Bundle,
/// Daten, Einstellungen, root-eigene System-Backups) und die gewählten Berechtigungen von Grantry.
public struct SelfUninstallPlan: Hashable, Sendable {
    public let files: [LeftoverCandidate]
    public let grants: [PermissionGrant]
    /// `false`: Die Dateien werden nur frisch abgeglichen (`TrashPerforming.settledOutcome`), nie an den Finder
    /// gegeben – Wiederholung bei schon entsorgtem Bundle (#143).
    let trashesFiles: Bool

    init(files: [LeftoverCandidate], grants: [PermissionGrant], trashesFiles: Bool = true) {
        self.files = files
        self.grants = grants
        self.trashesFiles = trashesFiles
    }

    /// Dateien und Berechtigungen aus dem Plan des Entfernen-Blatts (`RemovalPlanning`: Auswahl, `ActionPolicy`).
    /// Autostart-Einträge bleiben außen vor – Helper und Login-Item meldet `SelfUninstaller` über `SMAppService` ab.
    public init(_ plan: RemovalPlan) {
        self.init(files: plan.files, grants: plan.grants)
    }

    /// Ob das App-Bundle selbst dabei ist – nur dann ist es eine Deinstallation, sonst ein Aufräumen.
    public var includesApp: Bool { files.contains { $0.kind == .appBundle } }
}

public struct SelfUninstallReport: Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        /// Der privilegierte Helper (LaunchDaemon über `SMAppService`).
        case helper
        /// „Beim Anmelden starten“ (`SMAppService.mainApp`).
        case loginItem
        case grant(PermissionGrant)
        case file(LeftoverCandidate)
    }

    public struct Entry: Hashable, Sendable {
        public let subject: Subject
        public let result: RemovalReport.Result
    }

    public var entries: [Entry]
    /// Warum der Finder nicht gesteuert werden darf (keine Freigabe oder nicht verfügbar) – dann wurde nichts
    /// verändert; `nil`, wenn die Freigabe bestand oder nicht nötig war.
    public var finderAccessFailure: String?
    /// Der gescheiterte Schritt, dessentwegen alle nachfolgenden ausgelassen wurden (#140); diese stehen mit
    /// `SelfUninstaller.blockedReason` im Bericht. `nil`, wenn nichts deswegen ausgelassen wurde.
    public var blockedBy: Subject?

    init(entries: [Entry], finderAccessFailure: String?, blockedBy: Subject? = nil) {
        self.entries = entries
        self.finderAccessFailure = finderAccessFailure
        self.blockedBy = blockedBy
    }

    init(entries: [Entry], automationDenied: Bool, blockedBy: Subject? = nil) {
        self.init(
            entries: entries, finderAccessFailure: automationDenied ? RemovalExecutor.automationDeniedReason : nil,
            blockedBy: blockedBy
        )
    }

    /// Keine Automation-Freigabe für den Finder – nichts wurde verändert.
    public var automationDenied: Bool { finderAccessFailure == RemovalExecutor.automationDeniedReason }

    /// Das App-Bundle liegt im Papierkorb – Grantry ist deinstalliert und beendet sich.
    public var appRemoved: Bool { removedFile { $0.kind == .appBundle } }

    /// Die Einstellungsdatei von Grantry (`~/Library/Preferences/<Bundle-ID>.plist`) war Teil des Plans und liegt im
    /// Papierkorb.
    public var preferencesRemoved: Bool {
        removedPreferencesFile != nil
    }

    /// Die Einstellungsdatei, wenn sie (laut Bericht) im Papierkorb liegt – vor dem Leeren erneut zu prüfen.
    public var removedPreferencesFile: LeftoverCandidate? {
        entries.lazy.compactMap { entry -> LeftoverCandidate? in
            guard case .file(let file) = entry.subject, entry.result.isDone, Self.isPreferencesFile(file) else { return nil }
            return file
        }.first
    }

    static func isPreferencesFile(_ file: LeftoverCandidate) -> Bool {
        file.kind == .preferences && (file.path as NSString).lastPathComponent == SelfUninstaller.preferencesFileName
    }

    /// Ob das Beenden die Einstellungen leeren soll (`SelfUninstaller.clearPreferences`): nur nach einer Deinstallation,
    /// bei der der Nutzer die Einstellungen mit ausgewählt hatte. Abgewählte Einstellungen bleiben – es gäbe keine
    /// Sicherung im Papierkorb, aus der sie zurückkämen (#156).
    public var clearsPreferences: Bool { appRemoved && preferencesRemoved }

    // MARK: Vollständigkeit (#143) – einzige Definition; Titel, Ton, Wiederholung, Fortschritt und Meldung leiten
    // sich daraus ab.

    /// Ob ein Gegenstand seinen Endzustand erreicht hat: erledigt – oder, bei einem Dienst, nicht angemeldet gewesen.
    static func isSettled(_ entry: Entry) -> Bool {
        switch entry.subject {
        case .helper, .loginItem: entry.result.isDone || entry.result == .skipped(SelfUninstaller.notRegisteredReason)
        case .grant, .file: entry.result.isDone
        }
    }

    /// Gegenstände des Plans ohne Endzustand (gescheitert, ausgelassen, ohne Finder-Freigabe nicht angefasst).
    public var openEntries: [Entry] { entries.filter { !Self.isSettled($0) } }

    /// Vollständig genau dann, wenn jeder Gegenstand des bestätigten Plans – Dienste, Berechtigungen samt Automation,
    /// Dateien – erledigt bzw. nicht nötig ist.
    public var isComplete: Bool { openEntries.isEmpty }

    /// Dienste, die noch bei macOS angemeldet sein können. Liegt Grantry schon im Papierkorb, blieben sie nach dem
    /// Beenden verwaist zurück; die laufende App kann die Abmeldung noch wiederholen.
    public var servicesStillRegistered: [Subject] {
        openEntries.map(\.subject).filter { [.helper, .loginItem].contains($0) }
    }

    /// Berechtigungen, die nicht zurückgesetzt sind.
    public var grantsLeftBehind: [PermissionGrant] {
        openEntries.compactMap { if case .grant(let grant) = $0.subject { grant } else { nil } }
    }

    /// Gewählte Dateien, die nicht im Papierkorb liegen.
    public var filesLeftBehind: [LeftoverCandidate] {
        openEntries.compactMap { if case .file(let file) = $0.subject { file } else { nil } }
    }

    /// Ein vorausgesetzter Schritt ist gescheitert; was danach kam, wurde nicht angefasst (#156, #140).
    public var isAborted: Bool { blockedBy != nil }

    private func removedFile(_ matches: (LeftoverCandidate) -> Bool) -> Bool {
        entries.contains { entry in
            if case .file(let file) = entry.subject { matches(file) && entry.result.isDone } else { false }
        }
    }
}

/// Führt „Grantry deinstallieren …“ aus (#115) – als Folge von Stufen, deren jede die Voraussetzung der folgenden ist
/// (#140): Scheitert eine Stufe, läuft keine spätere mehr; deren Gegenstände stehen mit `blockedReason` im Bericht,
/// `SelfUninstallReport.blockedBy` nennt den blockierenden Schritt. So folgt nie ein irreversibler Schritt auf einen
/// gescheiterten, den er voraussetzt. Reihenfolge:
///
/// 0. Dateien, deren bestätigtes Original nachweislich schon im Papierkorb liegt (`TrashPerforming.settledOutcome`, etwa
///    nach einem verspätet erfolgreichen Finder-Auftrag), gelten als erledigt und gehen nicht mehr an den Finder (#143).
/// 1. Bleiben offene Dateien → Automation-Freigabe für den Finder prüfen; ohne Freigabe nichts tun.
/// 2. Helper, dann Login-Item abmelden (`SMAppService`) – die launchd-Plist des Helpers liegt im App-Bundle, danach
///    ließe er sich nicht mehr abmelden. Ein nicht registrierter Dienst gilt als erfüllt (`notRegisteredReason`),
///    ebenso einer, der trotz Fehlermeldung nicht mehr registriert ist: Eine Wiederholung setzt am tatsächlichen
///    Zustand auf, statt an einem schon abgemeldeten Dienst zu scheitern.
/// 3. Berechtigungen zurücksetzen, solange die App installiert ist (`tccutil` löst die Bundle-ID über Launch Services
///    auf, siehe `ServiceReset`) – außer Automation: Ohne sie dürfte Grantry den Finder nicht mehr steuern. Scheitert
///    eine, bleiben die Dateien liegen: Ohne die App ließe sie sich nicht mehr zurücksetzen.
/// 4. Alle Dateien mit **einem** Finder-Auftrag in den Papierkorb, jede unmittelbar davor durch den `RemovalGuard`
///    (dasselbe Objekt wie bei der Suche). Für root-eigene Einträge fragt der Finder nach dem Passwort.
/// 5. Automation zurücksetzen (kann nach dem Papierkorb scheitern – steht dann im Bericht); nur wenn Grantry entfernt
///    ist oder keine Datei liegen blieb – sonst braucht die Wiederholung die Finder-Freigabe noch.
///
/// Die Einstellungen der App leert erst das Beenden (`clearPreferences()`, nur wenn `SelfUninstallReport.clearsPreferences`):
/// Bis dahin läuft Grantry weiter und schriebe sie sonst neu.
///
/// Bricht der Nutzer die Passwortabfrage ab, bleibt Grantry installiert; der Helper ist dann abgemeldet und lässt sich
/// in der Einrichtung neu installieren.
public struct SelfUninstaller: Sendable {
    static let notRegisteredReason = "War nicht angemeldet"
    /// Wiederholung bei entsorgtem Bundle: Eine nicht (mehr) im Papierkorb liegende Datei gibt Grantry nicht erneut an
    /// den Finder (#143).
    static let notTrashedAgainReason = "Nicht im Papierkorb – Grantry legt sie nicht erneut hinein"
    /// Beim Abgleich am Ende eines Laufs nicht (mehr) nachweislich im Papierkorb – etwa währenddessen zurückgelegt (#143).
    static let notInTrashAnymoreReason = "Liegt nicht (mehr) nachweislich im Papierkorb – evtl. zurückgelegt"
    /// Grund der nach einem gescheiterten vorausgesetzten Schritt ausgelassenen Schritte (#140).
    static let blockedReason = "Nicht angefasst, weil ein vorheriger Schritt fehlschlug"
    /// Datei der Einstellungen unter `~/Library/Preferences`; die Domain leert `clearPreferences()`.
    static let preferencesFileName = GrantryIdentity.appBundleID + ".plist"

    let helper: any DaemonService
    let loginItem: any AppServiceRegistration
    let permissions: any PermissionResetting
    let trash: any TrashPerforming
    let removalGuard: RemovalGuard

    public init(trash: any TrashPerforming = FinderTrash()) {
        self.init(
            helper: SMAppDaemonService(plistName: GrantryIdentity.helperPlistName), loginItem: MainAppServiceRegistration(),
            permissions: PermissionActions(), trash: trash, removalGuard: RemovalGuard()
        )
    }

    init(
        helper: any DaemonService, loginItem: any AppServiceRegistration, permissions: any PermissionResetting,
        trash: any TrashPerforming, removalGuard: RemovalGuard
    ) {
        self.helper = helper
        self.loginItem = loginItem
        self.permissions = permissions
        self.trash = trash
        self.removalGuard = removalGuard
    }

    /// Leert die Einstellungen von Grantry – als Letztes beim Beenden nach einer Deinstallation, damit `cfprefsd` sie
    /// nicht neu schreibt.
    public static func clearPreferences(_ defaults: UserDefaults = .standard) {
        defaults.removePersistentDomain(forName: GrantryIdentity.appBundleID)
    }

    /// Führt den Plan aus. `progress` erfährt, wann ein Schritt beginnt und womit er endet (#143); jede Meldung wird
    /// abgewartet. Abbrechen lässt sich der Ablauf nicht: Ein an Finder oder `SMAppService` gesendeter Auftrag liefe
    /// ohnehin weiter.
    public func run(_ plan: SelfUninstallPlan, progress: SelfUninstallProgressHandler = { _ in }) async -> SelfUninstallReport {
        // Dateizustand stammt nie aus früheren Versuchen (#143): Jede Datei wird frisch abgeglichen. Was als Original
        // nachweislich im Papierkorb liegt (z. B. Finder-Auftrag nach Zeitüberschreitung doch beendet), gilt als
        // erledigt und braucht weder Finder-Freigabe noch Auftrag; alles andere ist offen – auch ein zurückgelegtes
        // Original. Ein Ersatzobjekt sperrt der `RemovalGuard`.
        // Zuerst, solange Grantry noch den Festplattenvollzugriff hat: Originale für den späteren Nachweis festhalten.
        trash.track(plan.files)
        let settled = Self.settledEntries(plan.files, trash: trash)
        if plan.trashesFiles, plan.files.contains(where: { settled[$0] == nil }) {
            await progress(.started(.finderAccess))
            let reason: String? = switch await trash.requestPermission() {
            case .granted: nil
            case .denied: RemovalExecutor.automationDeniedReason
            case .unavailable(let reason): reason
            }
            if let reason {
                let entries = Self.subjects(of: plan).map { subject in
                    SelfUninstallReport.Entry(subject: subject, result: Self.settled(subject, in: settled) ?? .skipped(reason))
                }
                return reverifyingFiles(SelfUninstallReport(entries: entries, finderAccessFailure: reason))
            }
            await progress(.finished(.finderAccess, []))
        }
        return reverifyingFiles(await Self.perform(stages(of: plan, settled: settled), progress: progress))
    }

    /// Abgleich aller Dateien am Ende jedes Laufs (#143), mit derselben Prüfung wie zu Beginn (`settledResult`):
    /// nachweislich im Papierkorb → erledigt (auch ein verspäteter Finder-Erfolg); früherer Erfolg ohne Nachweis →
    /// offen (etwa während des Laufs zurückgelegt); sonst bleibt das Ergebnis. Nur der Bericht ändert sich – schon
    /// getroffene Entscheidungen des Laufs (etwa die Automation zu behalten) rechtfertigt ein so spät erkannter Erfolg
    /// nicht nachträglich, `blockedBy` bleibt.
    private func reverifyingFiles(_ report: SelfUninstallReport) -> SelfUninstallReport {
        var report = report
        report.entries = report.entries.map { entry in
            guard case .file(let file) = entry.subject else { return entry }
            if let settled = Self.settledResult(of: file, trash: trash) {
                return SelfUninstallReport.Entry(subject: entry.subject, result: settled)
            }
            guard entry.result.isDone else { return entry }
            return SelfUninstallReport.Entry(subject: entry.subject, result: .failed(Self.notInTrashAnymoreReason))
        }
        return report
    }

    /// Ergebnis der Dateien, deren bestätigtes Original nachweislich schon im Papierkorb liegt
    /// (`TrashPerforming.settledOutcome`) – wie nach einem Auftrag bewertet (`RemovalExecutor.result`).
    private static func settledEntries(
        _ files: [LeftoverCandidate], trash: any TrashPerforming
    ) -> [LeftoverCandidate: RemovalReport.Result] {
        var settled: [LeftoverCandidate: RemovalReport.Result] = [:]
        for file in files {
            settled[file] = settledResult(of: file, trash: trash)
        }
        return settled
    }

    /// Ergebnis einer Datei, deren bestätigtes Original nachweislich im Papierkorb liegt; `nil` ohne Nachweis.
    private static func settledResult(of file: LeftoverCandidate, trash: any TrashPerforming) -> RemovalReport.Result? {
        trash.settledOutcome(of: file).map { outcome in
            RemovalExecutor.result(of: file, verdict: .allowed, in: TrashReport(outcomes: [file.path: outcome], failure: nil))
        }
    }

    private static func settled(
        _ subject: SelfUninstallReport.Subject, in settled: [LeftoverCandidate: RemovalReport.Result]
    ) -> RemovalReport.Result? {
        if case .file(let file) = subject { settled[file] } else { nil }
    }

    /// Alle Gegenstände des Plans (ohne Aufteilung der Automation).
    private static func subjects(of plan: SelfUninstallPlan) -> [SelfUninstallReport.Subject] {
        [.helper, .loginItem] + plan.grants.map { .grant($0) } + plan.files.map { .file($0) }
    }

    // MARK: - Stufen

    /// Ein Schritt des Ablaufs: zu welchem sichtbaren Schritt er gehört, was er anfasst, wie er es tut und welcher
    /// seiner Gegenstände – gescheitert – alle folgenden Stufen sperrt (`nil`: Voraussetzung der nächsten Stufe erfüllt).
    /// `settled`: vorab festgestellte Ergebnisse (reine Feststellung, kein Eingriff, #143) – sie gelten auch, wenn die
    /// Stufe nach einem früheren Fehler ausgelassen wird; als ausgelassen zählen dann nur die übrigen Gegenstände.
    struct Stage {
        let step: SelfUninstallStep
        let subjects: [SelfUninstallReport.Subject]
        var settled: [SelfUninstallReport.Subject: RemovalReport.Result] = [:]
        let perform: () async -> [SelfUninstallReport.Entry]
        let blocker: ([SelfUninstallReport.Entry]) -> SelfUninstallReport.Subject?
    }

    /// Führt die Stufen nacheinander aus; nach einer gescheiterten läuft keine weitere (#140). Stufen ohne Gegenstände
    /// zählen nicht. Jede ausgeführte Stufe meldet Beginn und Ergebnis an `progress`, jede ausgelassene ihr Ergebnis.
    static func perform(_ stages: [Stage], progress: SelfUninstallProgressHandler = { _ in }) async -> SelfUninstallReport {
        var entries: [SelfUninstallReport.Entry] = []
        var failed: SelfUninstallReport.Subject?
        var blockedBy: SelfUninstallReport.Subject?
        for stage in stages where !stage.subjects.isEmpty {
            if let failed {
                let skipped = stage.subjects.map { subject in
                    SelfUninstallReport.Entry(subject: subject, result: stage.settled[subject] ?? .skipped(blockedReason))
                }
                entries += skipped
                blockedBy = failed
                await progress(.finished(stage.step, skipped))
                continue
            }
            await progress(.started(stage.step))
            let results = await stage.perform()
            await progress(.finished(stage.step, results))
            entries += results
            failed = stage.blocker(results)
        }
        return SelfUninstallReport(entries: entries, automationDenied: false, blockedBy: blockedBy)
    }

    private func stages(of plan: SelfUninstallPlan, settled: [LeftoverCandidate: RemovalReport.Result]) -> [Stage] {
        let isAutomation = { (grant: PermissionGrant) in grant.service == PermissionCatalog.automationServiceID }
        let automation = plan.grants.filter(isAutomation), others = plan.grants.filter { !isAutomation($0) }
        let helper = helper, loginItem = loginItem
        return [
            // `.notFound` meldet der Helper nur, wenn `SMAppService` ihn nicht findet – kein Beleg, dass er nicht
            // registriert ist; also trotzdem abmelden. `SMAppService.mainApp` meldet es auch für eine nie registrierte App.
            serviceStage(.helper, absent: [.notRegistered], status: { helper.status }, unregister: helper.unregister),
            serviceStage(
                .loginItem, absent: [.notRegistered, .notFound], status: { loginItem.status }, unregister: loginItem.unregister
            ),
            Stage(
                step: .permissions, subjects: others.map { .grant($0) }, perform: { await reset(others) },
                blocker: Self.firstFailure
            ),
            Stage(
                step: .trash, subjects: plan.files.map { .file($0) },
                settled: Dictionary(uniqueKeysWithValues: settled.map { (SelfUninstallReport.Subject.file($0.key), $0.value) }),
                perform: { await trashFiles(plan.files, settled: settled, sending: plan.trashesFiles) },
                blocker: Self.appStillInstalled
            ),
            // Letzte Stufe – sie sperrt nichts mehr.
            Stage(
                step: .finderAutomation, subjects: automation.map { .grant($0) }, perform: { await reset(automation) },
                blocker: { _ in nil }
            ),
        ]
    }

    private func serviceStage(
        _ subject: SelfUninstallReport.Subject, absent: Set<SMAppService.Status>,
        status: @escaping () -> SMAppService.Status, unregister: @escaping () async throws -> Void
    ) -> Stage {
        Stage(
            step: .services, subjects: [subject],
            perform: {
                [SelfUninstallReport.Entry(subject: subject, result: await Self.unregister(absent: absent, status, unregister))]
            },
            blocker: Self.firstFailure
        )
    }

    private static func firstFailure(_ entries: [SelfUninstallReport.Entry]) -> SelfUninstallReport.Subject? {
        entries.first { if case .failed = $0.result { true } else { false } }?.subject
    }

    /// Nach dem Papierkorb: Blieb eine Datei liegen, während Grantry noch installiert ist, braucht die Wiederholung die
    /// Finder-Freigabe – die Automation bleibt dann. Als blockierend gilt bevorzugt das App-Bundle.
    private static func appStillInstalled(_ entries: [SelfUninstallReport.Entry]) -> SelfUninstallReport.Subject? {
        guard !SelfUninstallReport(entries: entries, automationDenied: false).appRemoved else { return nil }
        let open = entries.filter { !$0.result.isDone }
        let app = open.first { if case .file(let file) = $0.subject { file.kind == .appBundle } else { false } }
        return (app ?? open.first)?.subject
    }

    /// Meldet einen Dienst ab. Übersprungen wird er nur, wenn sein Status vorab zu `absent` gehört; jeder andere –
    /// auch ein unbekannter – gilt als registriert. Nach einem Fehler belegt allein `.notRegistered` die Abmeldung
    /// (etwa zwischenzeitlich abgemeldet); `.notFound` oder Unbekanntes behält den Fehler und sperrt die Folgestufen.
    private static func unregister(
        absent: Set<SMAppService.Status>, _ status: () -> SMAppService.Status, _ unregister: () async throws -> Void
    ) async -> RemovalReport.Result {
        guard !absent.contains(status()) else { return .skipped(notRegisteredReason) }
        do {
            try await unregister()
            return .done
        } catch {
            return status() == .notRegistered ? .done : .failed(ActionCoordinator.message(for: error))
        }
    }

    private func reset(_ grants: [PermissionGrant]) async -> [SelfUninstallReport.Entry] {
        var entries: [SelfUninstallReport.Entry] = []
        for grant in grants {
            let result: RemovalReport.Result
            do {
                try await permissions.reset(grant)
                result = .done
            } catch {
                result = .failed(ActionCoordinator.message(for: error))
            }
            entries.append(SelfUninstallReport.Entry(subject: .grant(grant), result: result))
        }
        return entries
    }

    /// Legt die offenen Dateien in den Papierkorb; schon entsorgte (`settled`) gehen nicht mehr an den Finder. Ohne
    /// `sending` bleiben die offenen liegen (`notTrashedAgainReason`).
    private func trashFiles(
        _ files: [LeftoverCandidate], settled: [LeftoverCandidate: RemovalReport.Result], sending: Bool
    ) async -> [SelfUninstallReport.Entry] {
        guard sending else {
            return files.map { .init(subject: .file($0), result: settled[$0] ?? .skipped(Self.notTrashedAgainReason)) }
        }
        let removalGuard = removalGuard
        let verify: @Sendable (LeftoverCandidate) -> RemovalVerdict = { removalGuard.check($0, allowingAppleIDOf: nil) }
        let open = files.filter { settled[$0] == nil }
        let verdicts = Dictionary(open.map { ($0, verify($0)) }) { first, _ in first }
        let allowed = open.filter { verdicts[$0] == .allowed }
        let report = allowed.isEmpty ? TrashReport(outcomes: [:], failure: nil) : await trash.moveToTrash(allowed, verifying: verify)
        return files.map { file in
            let result = settled[file] ?? RemovalExecutor.result(of: file, verdict: verdicts[file] ?? .allowed, in: report)
            return SelfUninstallReport.Entry(subject: .file(file), result: result)
        }
    }
}
