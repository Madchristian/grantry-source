import GrantryCharts
import ManagerKit
import SwiftUI

/// Eine Beobachtung (#127) im Lagebild (LB-3.4, #546): solange sie läuft, die bisher neuen Einträge und „Beobachtung
/// beenden“; danach Hinweise, die Bilanz als Zählkacheln, die Einträge je Art als Sprungzeilen, das Aufräumen gegen den
/// aktuellen Stand und die Protokolle früherer Aufräum-Durchgänge. Bestätigungen, Texte, Vorauswahl und Abläufe wie
/// bisher; Systemdialoge bleiben nativ.
struct ObservationDetailView: View {
    let appModel: AppModel
    let observationID: UUID
    @Environment(MainWindowModel.self) private var window
    @State private var observation: InstallationObservation?
    @State private var cleanup: ObservationCleanupModel?
    @State private var isLoaded = false
    @State private var pendingPlan: ObservationCleanupPlan?
    @State private var confirmsDelete = false

    private var observations: ObservationModel { appModel.observations }
    private var actions: ActionRunner { appModel.actions }

    var body: some View {
        ActionResultContainer(actions: actions, context: .observations) {
            if let observation {
                content(observation)
            } else if isLoaded {
                // Auch eine unlesbare laufende Beobachtung muss sich löschen lassen, sonst blockiert sie jeden neuen Start.
                VStack(spacing: InstrumentSpacing.group) {
                    InstrumentEmptyState(symbol: "exclamationmark.triangle",
                                         title: String(localized: "Beobachtung nicht lesbar"),
                                         message: String(localized: "Die gespeicherte Beobachtung ließ sich nicht laden."))
                    Button("Beobachtung löschen …", role: .destructive) { confirmsDelete = true }
                }
                .padding(.bottom, InstrumentSpacing.empty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .instrumentPanel()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).instrumentPanel()
            }
        }
        // Neu laden, sobald sich die Beobachtung in der Ablage ändert (beendet, aufgeräumt).
        .task(id: observations.summaries.first { $0.id == observationID }) { await load() }
        .onChange(of: appModel.monitoring.snapshot?.takenAt) { _, _ in
            cleanup?.refresh(current: appModel.monitoring.snapshot)
        }
        .actionConfirmation(for: $pendingPlan, confirmation: { plan in
            ActionConfirmation.observationCleanup(plan, name: observation?.name ?? "")
        }) { plan in
            Task {
                guard let report = await actions.performObservationCleanup(plan, context: .observations) else { return }
                await observations.recordCleanup(report, observationID: observationID)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmsDelete) {
            Button("Löschen", role: .destructive) {
                Task {
                    await observations.delete(id: observationID)
                    window.selectedObservationID = nil
                }
            }
        } message: {
            Text("Gelöscht wird nur das Protokoll in Grantry – auf dem Mac ändert sich nichts.")
        }
    }

    private var deleteTitle: String {
        observation?.isActive == true
            ? String(localized: "Beobachtung abbrechen und löschen?")
            : String(localized: "Beobachtung löschen?")
    }

    private func load() async {
        let loaded = await observations.observation(id: observationID)
        observation = loaded
        cleanup = loaded.flatMap(ObservationCleanupModel.init)
        cleanup?.refresh(current: appModel.monitoring.snapshot)
        isLoaded = true
    }

    // MARK: - Inhalt

    /// Bilanz der beendeten Beobachtung; laufend gegen den jüngsten Scan (ohne Aufräumen).
    private func presentation(_ observation: InstallationObservation) -> (ObservationBalancePresentation, ObservationBalance)? {
        if let cleanup {
            return (ObservationBalancePresentation(balance: cleanup.balance, attribution: cleanup.attribution), cleanup.balance)
        }
        guard observation.isActive, let current = appModel.monitoring.snapshot else { return nil }
        let balance = ObservationBalance(baseline: observation.baseline, final: current)
        let attribution = ObservationAttribution(observationName: observation.name, newApps: balance.newApps)
        return (ObservationBalancePresentation(balance: balance, attribution: attribution), balance)
    }

    private func content(_ observation: InstallationObservation) -> some View {
        let balance = presentation(observation)
        let rows = Dictionary((balance?.0.sections ?? []).flatMap(\.rows).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return ObservationDetailPanel(
            content: ObservationsBoardMapping.detail(observation, presentation: balance?.0,
                                                     balance: observation.isActive ? nil : balance?.1)
        ) { row in
            if let event = rows[row.id]?.event { window.show(event) }
        } actions: {
            actionRow(observation)
        } progress: {
            if observation.isActive { progress }
        } rowAccessory: { row in
            if let change = rows[row.id]?.event.commandChange {
                CommandChangeDisclosure(change: change)
            }
        } cleanup: {
            if let cleanup, !(balance?.0.isEmpty ?? true) {
                CleanupGroup(cleanup: cleanup, actions: actions, observationID: observationID,
                             removeWithLeftovers: { window.requestRemoval(of: $0) }) { prepareCleanup(cleanup) }
            }
        }
    }

    /// Knopfzeile unter dem Kopf: laufend „Beobachtung beenden“ und „Beobachtung abbrechen …“, sonst „Beobachtung
    /// löschen …“; beim Beenden „Wird beendet …“ daneben.
    private func actionRow(_ observation: InstallationObservation) -> some View {
        DetailActions(runningText: observations.phase == .finishing ? String(localized: "Wird beendet …") : nil) {
            if observation.isActive {
                Button("Beobachtung beenden") { Task { await observations.finish() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(observations.isBusy)
            }
            Button(observation.isActive ? "Beobachtung abbrechen …" : "Beobachtung löschen …", role: .destructive) {
                confirmsDelete = true
            }
            .disabled(observations.isBusy)
        }
    }

    /// Laufend: beim Beenden der Abschluss-Scan als Spur, sonst die Anleitung.
    @ViewBuilder
    private var progress: some View {
        if observations.phase == .finishing {
            let scan = appModel.monitoring.scanProgress
            ScanProgressText(progress: scan) { text in
                ProgressSpur(title: String(localized: "Abschluss-Scan"), detail: text,
                             fraction: scan.isIndeterminate ? nil : scan.fraction, tone: .info)
            }
        } else {
            InstrumentNote(String(localized: "Installiere und starte jetzt das Tool. Neue Einträge erscheinen hier nach jedem Scan."),
                           kind: .info)
        }
    }

    private func prepareCleanup(_ cleanup: ObservationCleanupModel) {
        Task {
            pendingPlan = await cleanup.preparePlan(scanner: appModel.leftovers, snapshot: appModel.monitoring.snapshot)
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

/// Gruppe „Aufräumen“ am Modell: Auswahl über `RemovalSelection` (Vorauswahl unverändert), „Mit Resten entfernen …“
/// öffnet das Entfernen-Blatt der App.
private struct CleanupGroup: View {
    @Bindable var cleanup: ObservationCleanupModel
    let actions: ActionRunner
    let observationID: UUID
    let removeWithLeftovers: (InstalledApp) -> Void
    let requestCleanup: () -> Void

    var body: some View {
        ObservationCleanupGroup(
            content: ObservationsBoardMapping.cleanup(
                offer: cleanup.offer, hasSelection: cleanup.hasSelection, canStart: actions.canStart,
                isPreparing: cleanup.isPreparing,
                isRunning: actions.runningRecordID == ObservationCleanupPlan.id(for: observationID)
            ),
            isSelected: { Binding($cleanup.selection, id: $0) },
            removeWithLeftovers: { id in
                if case .installedApp(let app)? = cleanup.offer?.candidates.first(where: { $0.id == id })?.subject {
                    removeWithLeftovers(app)
                }
            },
            remove: requestCleanup
        )
    }
}
