import ManagerKit
import SwiftUI

/// Bereich „Aufräumen“ (Spec v3 §3/§5): Reste gelöschter Apps auf Knopfdruck, gruppiert mit Auswahl, verwaiste
/// Autostart-Einträge auswählbar, Berechtigungen entfernter Apps je Dienst mit „Für alle Apps zurücksetzen …“
/// (`ServiceReset`); „In den Papierkorb legen …“ mit Bestätigung (Return und Escape brechen ab).
struct CleanupView: View {
    let appModel: AppModel
    @State private var pendingPlan: RemovalPlan?
    @State private var pendingServiceReset: ServiceReset?

    private var cleanup: CleanupModel { appModel.cleanup }
    private var actions: ActionRunner { appModel.actions }

    var body: some View {
        @Bindable var cleanup = cleanup
        ActionResultContainer(actions: actions, context: .cleanup) {
            VStack(alignment: .leading, spacing: 0) {
                header
                SearchStatusView(search: cleanup.search, searchingTitle: "Reste gelöschter Apps werden gesucht …",
                                 retry: startSearch)
                    .padding([.horizontal, .bottom], 12)
                if isOutdated {
                    outdatedNotice
                }
                if let presentation = cleanup.presentation {
                    notes(presentation)
                }
                Divider()
                // Volle Restfläche, damit Leerzustände wie in den anderen Bereichen mittig stehen statt oben links.
                content(selection: $cleanup.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .actionConfirmation(for: $pendingPlan, confirmation: { ActionConfirmation.removal($0) }) { plan in
            guard !isOutdated else { return }
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

    /// Installierte Apps haben sich seit der Suche geändert oder das Ergebnis ist zu alt (Review I1).
    private var isOutdated: Bool {
        cleanup.isOutdated(comparedTo: appModel.monitoring.snapshot)
    }

    private var outdatedNotice: some View {
        HStack(spacing: 8) {
            NoticeList(notices: [String(localized: "Das Ergebnis ist veraltet – Apps haben sich seit der Suche geändert oder sie liegt länger zurück. Bitte erneut suchen.")])
            Button("Erneut suchen", action: startSearch)
                .disabled(cleanup.search.isSearching || appModel.monitoring.snapshot == nil)
        }
        .padding([.horizontal, .bottom], 12)
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(spacing: 12) {
            Button("Reste gelöschter Apps suchen", action: startSearch)
                .disabled(cleanup.search.isSearching || appModel.monitoring.snapshot == nil)
                .help(appModel.monitoring.snapshot == nil ? "Erst nach dem ersten Scan möglich" : "Sucht nur – entfernt nichts")
            Spacer(minLength: 8)
            if let presentation = cleanup.presentation, !presentation.isEmpty {
                Text(verbatim: presentation.summary(for: cleanup.selection))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            trashButton
        }
        .padding(12)
    }

    @ViewBuilder
    private var trashButton: some View {
        let plan = cleanup.plan
        let title = plan.map { ActionConfirmation.removal($0).confirmTitle } ?? String(localized: "In den Papierkorb legen")
        HStack(spacing: 6) {
            Button(role: .destructive) { pendingPlan = plan } label: { Text(verbatim: title + " …") }
                .disabled(plan?.isEmpty != false || !actions.canStart || cleanup.search.isSearching || isOutdated)
            if actions.runningRecordID == RemovalPlan.cleanupID {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Aktion läuft")
            }
        }
    }

    private func notes(_ presentation: CleanupPresentation) -> some View {
        let notes = [presentation.coverageNote, presentation.unreadableNote].compactMap(\.self)
        return Group {
            if !notes.isEmpty {
                NoticeList(notices: notes)
                    .padding([.horizontal, .bottom], 12)
            }
        }
    }

    // MARK: - Inhalt

    @ViewBuilder
    private func content(selection: Binding<RemovalSelection>) -> some View {
        if let presentation = cleanup.presentation {
            if presentation.isEmpty {
                ContentUnavailableView("Keine Reste gefunden", systemImage: "checkmark.circle",
                                       description: Text("Grantry hat keine Reste gelöschter Apps gefunden."))
            } else {
                CleanupList(presentation: presentation, selection: selection, actions: actions,
                            requestServiceReset: requestServiceReset)
            }
        } else if cleanup.search.phase == .idle {
            ContentUnavailableView(
                "Noch nicht gesucht", systemImage: MainSection.cleanup.systemImage,
                description: Text("Die Suche startet nur, wenn du sie anstößt. Entfernt wird erst nach deiner Bestätigung.")
            )
        } else {
            Spacer()
        }
    }
}

/// Fundliste des Aufräumens: Gruppen je Kennung, verwaiste Autostart-Einträge, Berechtigungen entfernter Apps.
private struct CleanupList: View {
    let presentation: CleanupPresentation
    @Binding var selection: RemovalSelection
    let actions: ActionRunner
    /// Fordert die Bestätigung an, den Dienst für alle Apps zurückzusetzen.
    let requestServiceReset: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            ForEach(presentation.groups) { group in
                Section {
                    ForEach(group.sections) { section in
                        ForEach(section.rows) { row in
                            SelectionToggleRow(row: row, kindTitle: section.title, selection: $selection)
                        }
                    }
                } header: {
                    SectionHeader(title: group.identifier, trailing: group.sizeText)
                }
            }
            if !presentation.autostartItems.isEmpty {
                Section("Autostart-Einträge ohne Programm") {
                    ForEach(presentation.autostartItems) { item in
                        SelectionToggleRow(autostartItem: item, selection: $selection)
                    }
                }
            }
            ForEach(presentation.grantServices) { group in
                Section {
                    ForEach(group.grants) { grant in
                        Text(verbatim: grant.client.displayName)
                    }
                } header: {
                    grantServiceHeader(group)
                } footer: {
                    if group == presentation.grantServices.last, let note = presentation.grantsNote {
                        Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Einzeln lässt sich eine Berechtigung entfernter Apps nicht zurücksetzen (`tccutil` braucht die installierte
    /// App), nur der ganze Dienst – die Bestätigung nennt, wer die Berechtigung noch verliert.
    private func grantServiceHeader(_ group: CleanupPresentation.GrantService) -> some View {
        HStack(spacing: 8) {
            Text("Berechtigungen entfernter Apps: \(group.serviceName)")
            Spacer(minLength: 8)
            if let url = PermissionCatalog.service(for: group.service).settingsURL {
                Button("In Systemeinstellungen öffnen") { openURL(url) }
                    .buttonStyle(.link)
            }
            Button("Für alle Apps zurücksetzen …") { requestServiceReset(group.service) }
                .disabled(!actions.canStart)
            if actions.runningRecordID == ServiceReset.recordID(for: group.service) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Aktion läuft")
            }
        }
    }
}
