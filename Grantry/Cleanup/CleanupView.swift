import GrantryCharts
import ManagerKit
import SwiftUI

/// Segment im Bereich „Aufräumen“; die Wahl merkt sich `MainWindowModel.cleanupSegment`.
enum CleanupSegment: Hashable {
    case leftovers, storage, processes, occupancy

    /// Segmente des Umschalters in dieser Reihenfolge.
    static var options: [(value: Self, label: String)] {
        [(.leftovers, String(localized: "App-Reste")), (.storage, String(localized: "Speicher")),
         (.processes, String(localized: "Prozesse")), (.occupancy, String(localized: "Belegung"))]
    }
}

/// Umschalter der Aufräumen-Segmente im Inhalt (`InstrumentSegments`, Standard § 3.9; Spec 2026-11-10 § 11.4).
struct CleanupSegmentSwitcher: View {
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        InstrumentSegments(String(localized: "Bereich"), selection: $window.cleanupSegment,
                           options: CleanupSegment.options)
    }
}

/// Bereich „Aufräumen“: Segmente „App-Reste“ (Reste gelöschter Apps), „Speicher“ (Speicherfresser, #215),
/// „Prozesse“ (verwaiste Agenten-Prozesse und gebootete Simulatoren, #221) und „Belegung“ (wo der Platz liegt, #403).
struct CleanupView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        @Bindable var window = window
        let openFullDiskAccess: (() -> Void)? = prerequisites.isFullDiskAccessMissing
            ? { Task { await prerequisites.perform(.openFullDiskAccessSettings) } } : nil
        // Jedes Segment zeigt den Umschalter `CleanupSegmentSwitcher` unter seiner Zustandszeile (Spec § 11.4).
        switch window.cleanupSegment {
        case .leftovers: OrphanCleanupView(appModel: appModel)
        case .storage:
            StorageCleanupView(model: appModel.storageCleanup, openFullDiskAccess: openFullDiskAccess,
                               focusedCategoryID: $window.storageFocusCategoryID) {
                onboarding.present()
            }
        case .processes:
            ProcessCleanupView(model: appModel.processCleanup, openFullDiskAccess: openFullDiskAccess) {
                onboarding.present()
            }
        case .occupancy:
            // Ohne bestätigten Festplattenvollzugriff lässt der Scan die Orte aus, die sonst eine Rückfrage auslösen.
            OccupancyView(model: appModel.occupancy, findings: appModel.taskManager.findings,
                          isFullDiskAccessMissing: prerequisites.fullDiskAccess != true,
                          openFullDiskAccess: { Task { await prerequisites.perform(.openFullDiskAccessSettings) } }) {
                window.storageFocusCategoryID = $0
                window.cleanupSegment = .storage
            }
        }
    }
}

/// Segment „App-Reste“ (Spec v3 §3/§5) im Lagebild (LB-4.2, #548; Entwurf LB-4.1, Spec 2026-11-10 § 11.4): Reste
/// gelöschter Apps auf Knopfdruck, gruppiert mit Häkchenzeilen, darüber Erweiterungen ohne App aus dem Inventar
/// (`ExtensionLeftoversBox`), verwaiste Autostart-Einträge auswählbar, Berechtigungen entfernter Apps je Dienst mit „Für
/// alle Apps zurücksetzen …“ (`ServiceReset`); unten die Aktionsleiste mit „In den Papierkorb legen …“ und Bestätigung
/// (Return und Escape brechen ab). Ergebnis, veraltet, Abbruch und fehlende Abdeckung stehen als Banner über den Funden.
struct OrphanCleanupView: View {
    let appModel: AppModel
    @State private var pendingPlan: RemovalPlan?
    @State private var pendingServiceReset: ServiceReset?

    private var cleanup: CleanupModel { appModel.cleanup }
    private var actions: ActionRunner { appModel.actions }

    var body: some View {
        @Bindable var cleanup = cleanup
        let presentation = cleanup.presentation
        let isOutdated = isOutdated
        CleanupBoard(
            head: LeftoversBoardMapping.head(LeftoverVerdict(
                phase: LeftoversBoardMapping.phase(cleanup.search.phase), presentation: presentation,
                extensionLeftovers: extensionLeftovers.count)),
            progress: LeftoversBoardMapping.progress(running: cleanup.search.progress.current, presentation: presentation,
                                                     isOutdated: isOutdated)
        ) {
            CleanupSegmentSwitcher()
        } banner: {
            banners(presentation, isOutdated: isOutdated)
        } content: {
            content(presentation, selection: $cleanup.selection)
        } bar: {
            actionBar(presentation, isOutdated: isOutdated)
        }
        .actionConfirmation(for: $pendingPlan, confirmation: { ActionConfirmation.removal($0) }) { plan in
            guard !self.isOutdated else { return }
            Task {
                // Nur nach tatsächlich ausgeführter Aktion neu suchen – sonst bliebe das Ergebnis der verworfenen
                // Aktion stehen, ohne dass etwas passiert ist.
                if await actions.performRemoval(plan, context: .cleanup) { startSearch() }
            }
        }
        .actionConfirmation(for: $pendingServiceReset, confirmation: { ActionConfirmation.resetService($0) }) { reset in
            Task {
                if await actions.resetService(reset, context: .cleanup) { startSearch() }
            }
        }
        #if DEBUG
        .onChange(of: appModel.monitoring.snapshot == nil, initial: true) { _, isMissing in
            guard !isMissing, DevelopmentLaunchOptions.autoSearchesCleanup, cleanup.search.phase == .idle else { return }
            startSearch()
        }
        #endif
    }

    /// Gegen den aktuellen Scan statt das Suchergebnis: Die Bestätigung nennt alle Apps, die die Berechtigung verlieren.
    private func requestServiceReset(_ service: String) {
        pendingServiceReset = appModel.monitoring.snapshot.flatMap { ServiceReset(service: service, in: $0) }
    }

    private func startSearch() {
        guard let snapshot = appModel.monitoring.snapshot else { return }
        cleanup.startSearch(in: snapshot)
    }

    /// Erweiterungen ohne App aus dem Inventar (TM-13.6) – unabhängig von der Suche.
    private var extensionLeftovers: [ExtensionLeftover] {
        appModel.presentation?.extensions.leftovers ?? []
    }

    /// Installierte Apps haben sich seit der Suche geändert oder das Ergebnis ist zu alt (Review I1).
    private var isOutdated: Bool {
        cleanup.isOutdated(comparedTo: appModel.monitoring.snapshot)
    }

    /// Suchen ist ohne Scan, während der Suche und während einer Aktion gesperrt.
    private var canSearch: Bool {
        appModel.monitoring.snapshot != nil && !cleanup.search.isSearching && actions.canStart
    }

    // MARK: - Banner

    /// Ergebnis der letzten Aktion, „veraltet“, Abbruch und fehlende Abdeckung über den Funden (§ 11.4 d).
    @ViewBuilder
    private func banners(_ presentation: CleanupPresentation?, isOutdated: Bool) -> some View {
        if let result = actions.result(in: .cleanup) {
            ActionResultBanner(result: result, dismiss: actions.dismissResult)
        }
        if isOutdated {
            InstrumentBanner(String(localized: "Ergebnis veraltet"),
                             message: String(localized: "Das Ergebnis ist veraltet – Apps haben sich seit der Suche geändert oder sie liegt länger zurück. Bitte erneut suchen."),
                             tone: .finding) {
                Button("Erneut suchen", action: startSearch).disabled(!canSearch)
            }
        }
        if cleanup.search.phase == .cancelled {
            InstrumentBanner(String(localized: "Suche abgebrochen"),
                             message: String(localized: "Suche abgebrochen – es wird nichts angeboten."), tone: .neutral)
        }
        if let note = presentation?.coverageNote {
            InstrumentBanner(String(localized: "Suche unvollständig"), message: note, tone: .finding)
        }
    }

    // MARK: - Leiste

    private func actionBar(_ presentation: CleanupPresentation?, isOutdated: Bool) -> some View {
        let plan = cleanup.plan
        let title = plan.map { ActionConfirmation.removal($0).confirmTitle } ?? String(localized: "In den Papierkorb legen")
        let isTrashing = actions.runningRecordID == RemovalPlan.cleanupID
        return InstrumentActionBar(scope: LeftoversBoardMapping.scope(presentation, selection: cleanup.selection),
                                   runningText: isTrashing ? String(localized: "Wird in den Papierkorb gelegt …") : nil) {
            if cleanup.search.isSearching {
                Button("Suche abbrechen", action: cleanup.search.cancel)
            } else {
                Button(presentation == nil ? "Reste gelöschter Apps suchen" : "Erneut suchen", action: startSearch)
                    .disabled(!canSearch)
                    .help(appModel.monitoring.snapshot == nil ? "Erst nach dem ersten Scan möglich" : "Sucht nur – entfernt nichts")
            }
        } trailing: {
            // Ohne Auswahl, ohne Ergebnis, bei veraltetem Ergebnis und während einer Aktion sichtbar gesperrt
            // (Korrektur 2 der Abnahme LB-4.1).
            Button(role: .destructive) { pendingPlan = plan } label: { Text(verbatim: title + " …") }
                .disabled(plan?.isEmpty != false || !actions.canStart || cleanup.search.isSearching || isOutdated)
        }
    }

    // MARK: - Inhalt

    @ViewBuilder
    private func content(_ presentation: CleanupPresentation?, selection: Binding<RemovalSelection>) -> some View {
        let extensions = extensionLeftovers
        if let presentation, !presentation.isEmpty || !extensions.isEmpty {
            CleanupList(presentation: presentation, extensionLeftovers: extensions, appModel: appModel,
                        selection: selection, requestServiceReset: requestServiceReset)
        } else if presentation != nil {
            InstrumentEmptyState(symbol: "checkmark.circle", title: String(localized: "Keine Reste gefunden"),
                                 message: String(localized: "Grantry hat keine Reste gelöschter Apps gefunden."))
        } else if !extensions.isEmpty {
            CleanupList(presentation: nil, extensionLeftovers: extensions, appModel: appModel, selection: selection,
                        requestServiceReset: requestServiceReset)
        } else if cleanup.search.phase == .idle {
            InstrumentEmptyState(symbol: MainSection.cleanup.systemImage, title: String(localized: "Noch nicht gesucht"),
                                 message: String(localized: "Die Suche startet nur, wenn du sie anstößt. Entfernt wird erst nach deiner Bestätigung."))
        }
    }
}

/// Fundliste des Aufräumens im Fund-Panel: Erweiterungen ohne App, Gruppen je Kennung, verwaiste Autostart-Einträge,
/// Berechtigungen entfernter Apps je Dienst als Einträge auf der Mulde. Während einer Aktion sind die Häkchen sichtbar,
/// aber gesperrt und blass (§ 11.4 e).
private struct CleanupList: View {
    let presentation: CleanupPresentation?
    let extensionLeftovers: [ExtensionLeftover]
    let appModel: AppModel
    @Binding var selection: RemovalSelection
    /// Fordert die Bestätigung an, den Dienst für alle Apps zurückzusetzen.
    let requestServiceReset: (String) -> Void
    @Environment(\.openURL) private var openURL

    private var actions: ActionRunner { appModel.actions }

    var body: some View {
        CleanupFindingList {
            if !extensionLeftovers.isEmpty {
                ExtensionLeftoversBox(leftovers: extensionLeftovers, appModel: appModel)
            }
            if let presentation {
                findings(presentation)
            }
        }
    }

    @ViewBuilder
    private func findings(_ presentation: CleanupPresentation) -> some View {
        Group {
            ForEach(presentation.groups) { group in
                SelectionGroupHeader(title: group.identifier, count: group.sections.reduce(0) { $0 + $1.rows.count },
                                     size: group.sizeText)
                ForEach(group.sections) { section in
                    ForEach(section.rows) { row in
                        SelectionToggleRow(row: row, kindTitle: section.title, selection: $selection)
                    }
                }
            }
            if !presentation.autostartItems.isEmpty {
                SelectionGroupHeader(title: String(localized: "Autostart-Einträge ohne Programm"),
                                     count: presentation.autostartItems.count)
                ForEach(presentation.autostartItems) { item in
                    SelectionToggleRow(autostartItem: item, selection: $selection)
                }
            }
        }
        .disabled(!actions.canStart)
        if !presentation.grantServices.isEmpty {
            SelectionGroupHeader(title: String(localized: "Berechtigungen entfernter Apps"),
                                 count: presentation.grants.count)
            ForEach(presentation.grantServices) { group in
                grantService(group, note: presentation.grantsNote)
            }
        }
        if let note = presentation.unreadableNote {
            InstrumentNote(note).padding(InstrumentSpacing.group)
        }
    }

    /// Einzeln lässt sich eine Berechtigung entfernter Apps nicht zurücksetzen (`tccutil` braucht die installierte
    /// App), nur der ganze Dienst – die Bestätigung nennt, wer die Berechtigung noch verliert.
    private func grantService(_ group: CleanupPresentation.GrantService, note: String?) -> some View {
        let isRunning = actions.runningRecordID == ServiceReset.recordID(for: group.service)
        return DetailItem(LeftoversBoardMapping.grantContent(group),
                          runningText: isRunning ? String(localized: "Wird zurückgesetzt …") : nil) {
            if let note { InstrumentNote(note) }
        } actions: {
            if let url = PermissionCatalog.service(for: group.service).settingsURL {
                Button("In Systemeinstellungen öffnen") { openURL(url) }
            }
            Button("Für alle Apps zurücksetzen …") { requestServiceReset(group.service) }
                .disabled(!actions.canStart)
        }
    }
}
