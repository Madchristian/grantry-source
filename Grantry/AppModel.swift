import AppKit
import ManagerKit
import Observation

/// App-weiter Kern: hält die gemeinsamen Dienste (Helper-Verbindung, App-Resolver) und die Überwachung, deren
/// Zustand es für SwiftUI spiegelt. Lebt so lange wie die App; die Überwachung läuft auch ohne Fenster.
@MainActor
@Observable
final class AppModel {
    /// Gespiegelter Zustand der Überwachung.
    private(set) var monitoring = MonitoringState()
    /// Lesbare Meldung, wenn der Verlauf nicht dauerhaft gespeichert werden kann (die Überwachung läuft dann nur
    /// im Speicher) oder die Überwachung gar nicht verfügbar ist.
    private(set) var storeError: String?
    /// Anzeige-Daten zum aktuellen Zustand, im Hintergrund neu berechnet, sobald sich Snapshot, Findings, Events
    /// oder Neuzugänge ändern (`PresentationPipeline`); `nil` vor dem ersten Snapshot.
    private(set) var presentation: PresentationSnapshot?

    /// Gemeinsame XPC-Verbindung zum Helper (BTM-Quelle, Versionsabfrage, Aktionen).
    let helperClient: HelperClient
    /// Führt die verändernden Aktionen der Oberfläche aus (über den `ActionCoordinator`: serialisiert, mit
    /// Wirkungsprüfung und Wiederherstellungsbelegen).
    let actions: ActionRunner
    /// Verlauf mit Paging und Wiederherstellungsbelegen.
    let history: HistoryModel
    /// Schließt Aktionen und die (Neu-)Installation des Helpers gegenseitig aus.
    let helperActivity = HelperActivityLock()
    /// Nachgeladene Größe und „zuletzt benutzt“ der installierten Apps.
    let appDetails = AppDetailsModel()
    /// Reste einer App (auf Abruf, Spec v3 §3).
    let leftovers = LeftoverScanner()
    /// Laufende Apps (Entfernen-Blatt und `ActionCoordinator`).
    let runningApps = WorkspaceRunningApplications()
    /// Bereich „Aufräumen“: Reste gelöschter Apps (auf Abruf).
    let cleanup: CleanupModel
    /// Bereich „Aufräumen“, Segment „Speicher“ (#215; auf Abruf).
    let storageCleanup: StorageCleanupModel
    /// Papierkorb für Plug-ins in Systemdiensten (Bereich „Erweiterungen“).
    let extensionRemover: ServicePluginRemover
    /// Bereich „Aufräumen“, Segment „Prozesse“ (#221; auf Abruf).
    let processCleanup: ProcessCleanupModel
    /// Bereich „Aufräumen“, Segment „Belegung“ (#403; auf Abruf).
    let occupancy: OccupancyModel
    /// Hinweis auf viele verwaiste Agenten-Bäume (#224; Prüfung alle 15 min, nur lesend).
    let orphanAgentAlerts: OrphanAgentAlerter
    /// „Installation beobachten“ (#127): laufende und gespeicherte Beobachtungen.
    let observations: ObservationModel
    /// Takt der Helper-Abfragen der Lauscher-Quelle (#128); nach einer Registrierung oder Neuinstallation des Helpers
    /// zurückgesetzt (`PrerequisitesModel`), damit der nächste Teilscan den Helper sofort fragt.
    let listenerSchedule = ListenerHelperSchedule()
    /// Von „Prozess beenden …“ beendete Lauscher (#128); geteilt von Lauscher-Quelle und `ProcessTerminator`.
    let listenerTerminations = ListenerTerminationLedger()
    /// Ablauf „Prozess beenden …“ im Bereich „Netzwerk“.
    @ObservationIgnored private(set) lazy var processTermination = ProcessTerminationFlow(
        resolver: ListenerProcessResolver(provider: helperClient), actions: actions, ledger: listenerTerminations,
        refresh: { [weak self] in await self?.scanNow(only: [.networkListeners]) }
    )
    /// Ablauf „Grantry deinstallieren …“ (#115); `stop()` wartet ihn ab und leert danach ggf. die Einstellungen (#156).
    let selfUninstall: SelfUninstallFlow
    /// Netzwerkaktivität (live über nettop); misst nur, solange die Ansicht „Aktivität“ sichtbar ist.
    let networkActivity = NetworkActivityModel()
    /// Takt gespeichert, gemeinsam für Fenster und Menüleiste (TM17, E2).
    let taskManager = TaskManagerModel(settings: UserDefaults.standard)
    /// Datenträger-Befunde (TM-15.5) für Lagezeile und Wachbuch: liest das Volume-Inventar nach einem Scan, höchstens alle
    /// 15 min.
    @ObservationIgnored private lazy var volumeFindings: VolumeFindingCheck = {
        let check = VolumeFindingCheck()
        check.onInventory = { [weak self] inventory, time in self?.recordVolumes(inventory, at: time) }
        return check
    }()
    /// Elemente der Menüleiste (TM6, TM17; Einstellung, Standard aus).
    @ObservationIgnored private(set) lazy var menuBarMeters = MenuBarMetersModel(taskManager: taskManager)
    /// „Task beenden“ im Task-Manager: eigene Prozesse direkt, fremde über den Helper mit Admin-Bestätigung je Prozess
    /// (TM9); fremde kommen in den Verlauf. Die Schutzliste prüft der Ablauf selbst, auf jedem Weg.
    @ObservationIgnored private(set) lazy var taskTermination = TaskTerminationFlow(
        actions: actions,
        terminator: ProcessTerminator(own: OwnProcessSignaler(policy: .taskManagerProcess()),
                                      privileged: HelperTaskTerminator(helper: helperClient), ledger: nil),
        allowsForeignProcesses: true, log: taskActionLog
    )
    /// „Priorität“ im Task-Manager (TM-9.3); jede Änderung kommt in den Verlauf.
    @ObservationIgnored private(set) lazy var taskPriority = TaskPriorityFlow(
        actions: actions, setter: TaskPrioritySetter(helper: helperClient), log: taskActionLog
    )
    /// Leistungsaufnahme und Takt über den Helper (TM-9.4); misst nur, solange der Tab „Leistung“ sichtbar ist. Jede
    /// Messung speist die Regel „Drosselung“ der Lagezeile (TM-14.2) und – eingeschaltet – das Wachbuch (TM-14.5).
    @ObservationIgnored private(set) lazy var sensors: SensorModel = {
        let sensors = SensorModel(source: helperClient)
        sensors.onReading = { [weak self] reading in
            self?.taskManager.record(sensors: reading)
            self?.watchbookRecorder.sensorsDidMeasure(reading)
        }
        return sensors
    }()
    /// Verlauf für Task-Manager-Aktionen; `nil` ohne Ablage.
    private var taskActionLog: (any TaskActionLogging)? { store as? any TaskActionLogging }
    /// CPU und Speicher fremder Prozesse über `/bin/ps`; misst nur, solange der Tab „Prozesse“ sichtbar ist.
    let foreignProcessUsage = ForeignProcessUsageModel()
    /// Stände von `sensors` und `foreignProcessUsage` zum Messtakt (#481): Übersicht, Leistung und Chip lesen nur diese,
    /// damit eine Antwort des Helpers oder von `ps` keinen eigenen Durchlauf zwischen zwei Takten auslöst.
    let frameSensors = FrameLatch(SensorSnapshot.empty) { $1.isNew(comparedTo: $0) }
    let frameForeignUsage = FrameLatch([Int32: ForeignProcessUsage]()) { $0 != $1 }
    /// Angemeldete Benutzer (utmpx) für den Tab „Benutzer“; gelesen nur, solange er sichtbar ist.
    let loginSessions = LoginSessionsModel()
    /// launchd-Dienste für den Tab „Dienste“; gelesen nur, solange er sichtbar ist.
    let launchdServices = LaunchdServicesModel()
    /// Starten und Stoppen eigener Agenten im Tab „Dienste“ (TM10); jede ausgeführte Aktion kommt in den Verlauf, danach
    /// werden die Dienste neu gelesen.
    @ObservationIgnored private(set) lazy var serviceControl = ServiceControlFlow(
        actions: actions, log: taskActionLog, refresh: { [weak self] in await self?.launchdServices.refresh() }
    )
    /// App-Verlauf des Task-Managers (je App und Stunde, 30 Tage); verbucht jeden Takt, solange der Task-Manager misst –
    /// ohne eigenen Dauerprozess.
    let appUsage: AppUsageModel
    /// Wachbuch (TM12, Einstellung, Standard aus): zeichnet im Hintergrund alle 10 s auf; misst der Task-Manager, nimmt
    /// es dessen Messungen (`TaskManagerModel.tap`), statt doppelt zu messen.
    let watchbook: WatchbookModel
    /// Längerer Leistungsverlauf aus dem Wachbuch für den Tab „Leistung“ (TM-14.5); liest nur, solange er sichtbar ist.
    let powerHistory: PowerHistoryModel
    @ObservationIgnored private let watchbookRecorder: WatchbookRecorder<ContinuousClock>
    /// Verdichtete Reihe des Wachbuchs für den Tab „Wachbuch“ (TM-12.5); liest nur, solange er sichtbar ist.
    var watchbookSeries: any WatchbookSeriesReading { watchbookRecorder }
    /// Größte Verbraucher an der Zeitmarke des Wachbuchs (TM-12.6); nur auf Anfrage des sichtbaren Tabs.
    var watchbookConsumers: any WatchbookConsumerReading { watchbookRecorder }

    /// `nil`, wenn keine Ablage geöffnet werden konnte – nicht einmal im Speicher.
    private let engine: MonitoringEngine?
    /// Ablage der Engine, für Abfragen über `monitoring.recentEvents` hinaus.
    private let store: (any SnapshotStore)?
    /// Alle `.added`-Events seit `RecordBadges.newItemInterval`; ergänzt `monitoring.recentEvents` für „neu seit
    /// 7 Tagen“ und das Badge „neu“, die über die jüngsten Events hinaus zählen.
    private var recentAdditions: [HistoryEvent] = []
    /// Eben in den Papierkorb gelegte Apps; fehlen in der Anzeige, bis ein danach begonnener Scan sie bestätigt.
    private var trashedApps = TrashedApps()
    /// Nach jedem neuen Snapshot (z. B. um die Einrichtung erneut zu prüfen).
    @ObservationIgnored var onNewSnapshot: (@MainActor (Snapshot) -> Void)?
    private var mirrorTask: Task<Void, Never>?
    /// `stop()` läuft: Der Bericht einer Deinstallation löst dann kein Beenden mehr aus.
    @ObservationIgnored private var isStopping = false
    private var additionsTask: Task<Void, Never>?
    /// Aufbewahrungsprüfung von App-Verlauf und Wachbuch (`scheduleRetention()`).
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    /// Erste Prüfung kurz nach dem Start, aber nicht im Gedränge von Start-Scan und Fensteraufbau.
    private static let retentionStartDelay: Duration = .seconds(60)
    private static let retentionInterval: Duration = .seconds(86_400)
    @ObservationIgnored private lazy var presentationPipeline = PresentationPipeline { [weak self] presentation in
        self?.presentation = presentation
        self?.appDetails.update(for: presentation?.installedApps ?? [])
    }

    /// Beobachtete Verzeichnisse: System-TCC-Datenbank, launchd-Verzeichnisse und die Ordner des Sicherheitsstatus;
    /// dessen einzelne Dateien beobachtet `ScanTriggers` über `SecurityPostureSource.watchedFiles`, die App-Ordner flach
    /// über `AppInventorySource.watchedDirectories`. Die Agenten-Konfigurationen (`AgentConfigSource.watchedFiles()`)
    /// zählen als Dateien, gefiltert per Inhalts-Stempel: Laufende Schreibvorgänge der Tools lösen keinen Scan aus.
    /// Erweiterungs- und Plug-in-Ordner beobachtet `ScanTriggers` nur, wenn sie bestehen
    /// (`ExtensionInventorySource.watchedDirectories()`), die Datenbank der Systemerweiterungen als Datei.
    static var watchedPaths: [String] {
        [
            "/Library/Application Support/com.apple.TCC",
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents").path,
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
        ] + SecurityPostureSource.watchedDirectories
    }

    /// - Parameter storage: Ablage von Verlauf, Wiederherstellungsbelegen und Benutzer-Backups.
    init(
        storage: StorageLocation = .standard,
        helperClient: HelperClient = HelperClient(),
        resolver: AppResolver = AppResolver(),
        notifier: any UserNotifying = UNUserNotificationCenterNotifier()
    ) {
        self.helperClient = helperClient

        let store: SwiftDataSnapshotStore?
        do {
            store = try SwiftDataSnapshotStore.live(in: storage)
        } catch {
            store = try? SwiftDataSnapshotStore.inMemory()
            storeError = store == nil
                ? "Überwachung nicht verfügbar: \(error.readableDescription)"
                : "Verlauf wird nicht gespeichert: \(error.readableDescription)"
        }
        self.store = store
        // Ein Schlüssel für Scan und Bearbeiten: Nur so sind Fingerabdrücke verborgener Befehle vergleichbar (#137).
        let fingerprinter = storage.secretFingerprinter()
        let listenerSchedule = listenerSchedule
        let listenerTerminations = listenerTerminations
        selfUninstall = SelfUninstallFlow.live(helperActivity: helperActivity)
        engine = store.map { store in
            MonitoringEngine(
                coordinator: ScanCoordinator(sources: StandardSources.v6(
                    btmProvider: helperClient, resolver: resolver, sockets: helperClient,
                    fingerprinter: fingerprinter, listenerSchedule: listenerSchedule,
                    listenerTerminations: listenerTerminations
                )),
                store: store,
                notifier: ChangeNotifier(notifier: notifier),
                triggers: ScanTriggers(
                    watcher: FSEventsWatcher(contentStamps: AgentConfigSource.contentStamps()), paths: Self.watchedPaths,
                    files: SecurityPostureSource.watchedFiles + AgentConfigSource.watchedFiles()
                        + ExtensionInventorySource.watchedFiles,
                    shallowPaths: AppInventorySource.watchedDirectories,
                    existingPaths: ExtensionInventorySource.watchedDirectories(),
                    sourceIntervals: [.networkListeners: .seconds(60)]
                ),
                // Die Einstellung wird je Event frisch gelesen; `SettingsStore` ist nicht `Sendable`, daher nichts einfangen.
                notificationPolicy: NotificationPolicy(listenerSetting: { ListenerNotificationPreferences().setting }),
                deepVerifier: DeepSignatureVerifier(cacheURL: storage.deepSignatureCacheURL),
                appRiskAcceptances: AppRiskAcceptanceStore(url: storage.appRiskAcceptancesURL),
                extensionRiskAcceptances: ExtensionRiskAcceptanceStore(url: storage.extensionRiskAcceptancesURL),
                scanDurationsURL: storage.scanDurationsURL
            )
        }
        let receipts = ReceiptStore(url: storage.receiptsURL)
        // Aktionen und Verlauf teilen die Ablage der Sicherungen – auch eine eigene (UI-Tests, zweite Instanz).
        let agentBackups = storage.agentBackups
        cleanup = CleanupModel(scanner: OrphanScanner(resolver: resolver))
        storageCleanup = StorageCleanupModel(remover: StorageRemover(trash: FinderTrash()),
                                             log: CleanupLog(url: storage.cleanupLogURL))
        extensionRemover = ServicePluginRemover(trash: FinderTrash())
        let processScanner = ProcessOverviewScanner()
        processCleanup = ProcessCleanupModel(scanner: processScanner, log: CleanupLog(url: storage.cleanupLogURL))
        occupancy = OccupancyModel(preferences: storageCleanup.preferences)
        orphanAgentAlerts = OrphanAgentAlerter(scanner: processScanner, notifier: notifier)
        let runningApps = runningApps
        actions = ActionRunner(helperActivity: helperActivity, coordinator: engine.map { engine in
            ActionCoordinator(
                permissions: PermissionActions(),
                autostart: AutostartActions(privileged: helperClient, userBackups: storage.userBackups),
                security: SecurityActions(privileged: helperClient),
                agentConfigs: AgentConfigActions(backups: agentBackups, fingerprinter: fingerprinter),
                processTermination: ProcessTerminator(privileged: helperClient, ledger: listenerTerminations),
                receipts: receipts,
                scanner: engine,
                // Echter Papierkorb nur hier, beim Speicher-Aufräumen (`StorageRemover`) und für Plug-ins in
                // Systemdiensten (`ServicePluginRemover`); die Vorgabe `UnavailableTrash` löscht nie (Leitplanke 7).
                trash: FinderTrash(),
                runningApps: runningApps
            )
        })
        history = HistoryModel(store: store, receipts: receipts, agentBackups: agentBackups)
        appUsage = AppUsageModel(store: AppUsageStore(url: storage.appUsageHistoryURL))
        // Die Einstellung wird je Prüfung frisch gelesen; `SettingsStore` ist nicht `Sendable`, daher nichts einfangen.
        let severeFindingAlerts = SevereFindingAlerts(notifier: notifier,
                                                      isEnabled: { SevereFindingAlertPreferences().isEnabled })
        let watchbookRecorder = WatchbookRecorder(store: WatchbookStore(directory: storage.watchbookDirectory),
                                                  clock: ContinuousClock(), alerts: severeFindingAlerts)
        self.watchbookRecorder = watchbookRecorder
        powerHistory = PowerHistoryModel(source: watchbookRecorder)
        watchbook = WatchbookModel(recorder: watchbookRecorder, thermal: taskManager.thermal, history: store)
        taskManager.tap = watchbookRecorder
        observations = ObservationModel(store: store, scanner: engine)
        actions.onRemovalExecuted = { [weak self] report in self?.removalExecuted(report) }
        taskManager.onFrame = { [weak self] frame in self?.frameArrived(frame) }
    }

    /// Nimmt die eben in den Papierkorb gelegten Apps sofort aus der Anzeige; den Scan stößt die Aktion selbst an.
    private func removalExecuted(_ report: RemovalReport) {
        trashedApps.record(report, at: .now)
        updatePresentation()
    }

    /// Je Takt: neue Stände für die Ansichten in derselben Aktualisierung, dann der App-Verlauf.
    private func frameArrived(_ frame: TaskManagerFrame) {
        frameSensors.offer(sensors.snapshot)
        frameForeignUsage.offer(foreignProcessUsage.usage)
        recordAppUsage(frame)
    }

    /// Verbucht einen Takt im App-Verlauf: laufende Apps für die Zuordnung, Netz aus nettop, solange es misst. Nur
    /// Takte mit Prozessmessung zählen, also die des Fensters; die Menüleiste liest keine Prozesse (`Consumer.sources`)
    /// und löst daher weder die App-Abfrage noch einen Schreibvorgang aus.
    private func recordAppUsage(_ frame: TaskManagerFrame) {
        guard !frame.snapshot.processes.isEmpty else { return }
        appUsage.record(frame, apps: WorkspaceRunningApplications.regularApps(), currentUID: getuid(),
                        network: networkActivity.processRates)
    }

    /// Hält die 30 Tage des App-Verlaufs auch ohne neue Takte ein, denn geladen wird die Datei erst mit dem Task-Manager:
    /// erstmals kurz nach dem Start, danach täglich, solange die App läuft. Ohne Datei kostet jeder Durchlauf nur eine
    /// Existenzprüfung, mit Datei höchstens ein Lesen und nur bei abgelaufenen Stunden ein Schreiben; im Messtakt
    /// geschieht dafür nie ein Dateizugriff. Im selben Durchlauf hält das Wachbuch seine 7 Tage ein, auch wenn es aus ist.
    private func scheduleRetention() {
        guard retentionTask == nil else { return }
        retentionTask = Task { [appUsage, watchbook] in
            var delay = Self.retentionStartDelay
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                appUsage.enforceRetention()
                watchbook.enforceRetention()
                delay = Self.retentionInterval
            }
        }
    }

    /// Spiegelt den Zustand und startet die Überwachung samt Hinweis auf verwaiste Agenten-Bäume, Wachbuch und die
    /// Aufbewahrungsprüfung von App-Verlauf und Wachbuch; weitere Aufrufe bleiben wirkungslos. Die Erlaubnis für
    /// Benachrichtigungen holt das Onboarding ein.
    func start() async {
        orphanAgentAlerts.start()
        watchbook.activate()
        scheduleRetention()
        guard let engine, mirrorTask == nil else { return }
        await observations.load()
        let states = await engine.states()
        mirrorTask = Task { [weak self] in
            for await state in states {
                self?.mirror(state)
            }
        }
        await engine.start()
    }

    /// Beim Beenden der App: wartet erst, bis laufende und eingereihte Aktionen samt Wiederherstellungsbeleg fertig
    /// sind (ohne auf deren Prüfscan zu warten) und eine laufende Deinstallation abgeschlossen ist (#156), beendet dann
    /// die Überwachung und meldet wartende Benachrichtigungen sofort. Liegt Grantry samt gewählter Einstellungen im
    /// Papierkorb, werden die Einstellungen zuletzt geleert. Zuvor enden das Wachbuch (schreibt Offenes, beendet
    /// laufende Befunde), nettop der Netzwerkaktivität und die Messung des Task-Managers (`stopAndWait()`) und der
    /// Hinweis auf verwaiste Agenten-Bäume.
    func stop() async {
        isStopping = true
        orphanAgentAlerts.stop()
        volumeFindings.cancel()
        await watchbook.stop()
        await networkActivity.stopAndWait()
        await taskManager.stopAndWait()
        retentionTask?.cancel()
        retentionTask = nil
        appUsage.flush()
        await actions.drain()
        await selfUninstall.drain()
        await engine?.stop()
        if selfUninstall.clearsPreferences { SelfUninstaller.clearPreferences() }
    }

    /// Dieselben Zustände wie in den jeweiligen Oberflächen, keine zweite Aktivitätsverwaltung.
    var canInstallUpdate: Bool {
        UpdateInstallationPolicy.canInstall(
            isCleaning: storageCleanup.phase == .cleaning || processCleanup.phase == .cleaning,
            isRemoving: actions.isRunning || selfUninstall.isRunning,
            helperActivity: helperActivity
        )
    }

    /// Die laufende Grantry in der App-Liste (`RemovalRoute.grantryItself`, am Pfad erkannt); `nil` vor dem ersten Scan
    /// oder wenn sie nicht an einem durchsuchten Ort liegt.
    var ownApp: InstalledApp? {
        presentation?.installedApps.first { RemovalRoute.route(for: $0) == .grantryItself }
    }

    /// „Grantry deinstallieren …“ (#115): führt den bestätigten Plan aus (`SelfUninstallFlow` – sperrt Aktionen und die
    /// Helper-Wartung, denn der Helper wird abgemeldet; läuft schon etwas, geschieht nichts). Fortschritt und Bericht
    /// zeigt das Entfernen-Blatt (`SelfUninstallFlow.progress`, #143). Wird das Beenden regulär ausgelöst, wartet
    /// `stop()` den Ablauf ab.
    func uninstallGrantry(_ plan: SelfUninstallPlan) {
        Task { _ = await selfUninstall.run(plan) }
    }

    /// „Erneut versuchen“: nur die noch offenen Teile des bestätigten Plans (`SelfUninstallFlow.retry()`, #143).
    func retryUninstall() {
        Task { _ = await selfUninstall.retry() }
    }

    /// Schließt den Bericht der Deinstallation; liegt Grantry im Papierkorb, beendet sich die App (außer `stop()` läuft
    /// schon).
    func closeSelfUninstall() {
        if selfUninstall.progress?.report?.appRemoved == true {
            if !isStopping { NSApp.terminate(nil) }
        } else {
            selfUninstall.dismiss()
        }
    }

    /// Vom Benutzer angefordert: Der Helper wird außerhalb seines 15-min-Takts gefragt (`ListenerHelperSchedule.reset`),
    /// damit der Vollscan auch die Dienste anderer Benutzer frisch liest statt nur eigene.
    func scanNow() async {
        listenerSchedule.reset()
        await engine?.scanNow()
    }

    /// Teilscan nur der Quellen `sources`.
    func scanNow(only sources: Set<SourceID>) async {
        await engine?.scanNow(only: sources)
    }

    func markAllRead() async {
        await engine?.markAllRead()
    }

    func setAppRiskAccepted(_ accepted: Bool, appID: String) async throws {
        guard let engine else { throw CocoaError(.featureUnsupported) }
        try await engine.setAppRiskAccepted(accepted, appID: appID)
    }

    func setExtensionRiskAccepted(_ accepted: Bool, extensionID: String) async throws {
        guard let engine else { throw CocoaError(.featureUnsupported) }
        try await engine.setExtensionRiskAccepted(accepted, extensionID: extensionID)
    }

    /// Übernimmt den Zustand der Engine; haben sich die Events geändert, werden die Neuzugänge neu geladen. Ein neuer
    /// Snapshot lässt App-Symbole erneut prüfen (fehlende und geänderte), bestätigt Entfernungen, prüft bei Fälligkeit
    /// die Datenträger und geht an `onNewSnapshot`.
    private func mirror(_ state: MonitoringState) {
        let eventsChanged = state.recentEvents != monitoring.recentEvents || additionsTask == nil
        let newSnapshot = state.snapshot.flatMap { $0.takenAt != monitoring.snapshot?.takenAt ? $0 : nil }
        // Fortschritt ändert nur die Anzeige: keine Snapshot-Aufbereitung oder Pipeline-Vergleiche je Schritt.
        let presentationChanged = newSnapshot != nil || eventsChanged || state.findings != monitoring.findings
            || state.activeSources != monitoring.activeSources
        if let newSnapshot {
            AppIconCache.shared.invalidate()
            trashedApps.prune(confirmedBy: newSnapshot)
            observations.update(with: newSnapshot)
            volumeFindings.scanFinished()
        }
        monitoring = state
        if presentationChanged { updatePresentation() }
        if eventsChanged {
            reloadRecentAdditions()
            watchbook.recordChanges(state.recentEvents)
        }
        if let newSnapshot { onNewSnapshot?(newSnapshot) }
    }

    /// Datenträger-Befunde in die Lagezeile (`TaskManagerModel`) und deren Beginn und Ende ins Wachbuch.
    private func recordVolumes(_ inventory: VolumeInventory, at time: Date) {
        taskManager.record(volumes: inventory, at: time)
        watchbook.recordStorageFindings(taskManager.findings.filter(\.kind.isStorage), at: time)
    }

    /// Reicht die Eingaben der Anzeige-Daten weiter; unveränderte Eingaben lösen keine Berechnung aus.
    private func updatePresentation() {
        presentationPipeline.update(
            PresentationInput(state: monitoring, recentAdditions: recentAdditions, trashedApps: trashedApps)
        )
    }

    /// Lädt die Neuzugänge im Hintergrund; eine neuere Anfrage ersetzt eine laufende.
    private func reloadRecentAdditions() {
        guard let store else { return }
        additionsTask?.cancel()
        additionsTask = Task { [weak self] in
            let since = Date.now.addingTimeInterval(-RecordBadges.newItemInterval)
            guard let additions = try? await store.additions(since: since), !Task.isCancelled else { return }
            self?.recentAdditions = additions
            self?.updatePresentation()
        }
    }
}
