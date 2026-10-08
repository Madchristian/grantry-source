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
    @ObservationIgnored private lazy var presentationPipeline = PresentationPipeline { [weak self] presentation in
        self?.presentation = presentation
        self?.appDetails.update(for: presentation?.installedApps ?? [])
    }

    /// Beobachtete Verzeichnisse: System-TCC-Datenbank, launchd-Verzeichnisse und die Ordner des Sicherheitsstatus;
    /// dessen einzelne Dateien beobachtet `ScanTriggers` über `SecurityPostureSource.watchedFiles`, die App-Ordner flach
    /// über `AppInventorySource.watchedDirectories`. Die Agenten-Konfigurationen (`AgentConfigSource.watchedFiles()`)
    /// zählen als Dateien, gefiltert per Inhalts-Stempel: Laufende Schreibvorgänge der Tools lösen keinen Scan aus.
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
                coordinator: ScanCoordinator(sources: StandardSources.v5(
                    btmProvider: helperClient, resolver: resolver, sockets: helperClient,
                    fingerprinter: fingerprinter, listenerSchedule: listenerSchedule,
                    listenerTerminations: listenerTerminations
                )),
                store: store,
                notifier: ChangeNotifier(notifier: notifier),
                triggers: ScanTriggers(
                    watcher: FSEventsWatcher(contentStamps: AgentConfigSource.contentStamps()), paths: Self.watchedPaths,
                    files: SecurityPostureSource.watchedFiles + AgentConfigSource.watchedFiles(),
                    shallowPaths: AppInventorySource.watchedDirectories,
                    sourceIntervals: [.networkListeners: .seconds(60)]
                ),
                // Die Einstellung wird je Event frisch gelesen; `SettingsStore` ist nicht `Sendable`, daher nichts einfangen.
                notificationPolicy: NotificationPolicy(listenerSetting: { ListenerNotificationPreferences().setting }),
                deepVerifier: DeepSignatureVerifier()
            )
        }
        let receipts = ReceiptStore(url: storage.receiptsURL)
        // Aktionen und Verlauf teilen die Ablage der Sicherungen – auch eine eigene (UI-Tests, zweite Instanz).
        let agentBackups = storage.agentBackups
        cleanup = CleanupModel(scanner: OrphanScanner(resolver: resolver))
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
                // Einzige Stelle mit echtem Papierkorb; die Vorgabe `UnavailableTrash` löscht nie (Leitplanke 7).
                trash: FinderTrash(),
                runningApps: runningApps
            )
        })
        history = HistoryModel(store: store, receipts: receipts, agentBackups: agentBackups)
        observations = ObservationModel(store: store, scanner: engine)
        actions.onRemovalExecuted = { [weak self] report in self?.removalExecuted(report) }
    }

    /// Nimmt die eben in den Papierkorb gelegten Apps sofort aus der Anzeige; den Scan stößt die Aktion selbst an.
    private func removalExecuted(_ report: RemovalReport) {
        trashedApps.record(report, at: .now)
        updatePresentation()
    }

    /// Spiegelt den Zustand und startet die Überwachung; weitere Aufrufe bleiben wirkungslos. Die Erlaubnis für
    /// Benachrichtigungen holt das Onboarding ein.
    func start() async {
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
    /// Papierkorb, werden die Einstellungen zuletzt geleert. Zuvor endet nettop der Netzwerkaktivität (`stopAndWait()`).
    func stop() async {
        isStopping = true
        await networkActivity.stopAndWait()
        await actions.drain()
        await selfUninstall.drain()
        await engine?.stop()
        if selfUninstall.clearsPreferences { SelfUninstaller.clearPreferences() }
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

    /// Übernimmt den Zustand der Engine; haben sich die Events geändert, werden die Neuzugänge neu geladen. Ein neuer
    /// Snapshot lässt App-Symbole erneut prüfen (fehlende und geänderte), bestätigt Entfernungen und geht an
    /// `onNewSnapshot`.
    private func mirror(_ state: MonitoringState) {
        let eventsChanged = state.recentEvents != monitoring.recentEvents || additionsTask == nil
        let newSnapshot = state.snapshot.flatMap { $0.takenAt != monitoring.snapshot?.takenAt ? $0 : nil }
        if let newSnapshot {
            AppIconCache.shared.invalidate()
            trashedApps.prune(confirmedBy: newSnapshot)
            observations.update(with: newSnapshot)
        }
        monitoring = state
        updatePresentation()
        if eventsChanged { reloadRecentAdditions() }
        if let newSnapshot { onNewSnapshot?(newSnapshot) }
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
