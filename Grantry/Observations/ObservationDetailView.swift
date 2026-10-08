import ManagerKit
import SwiftUI

/// Eine Beobachtung (#127): solange sie läuft, die bisher neuen Einträge und „Beobachtung beenden“; danach die Bilanz
/// nach Art, das Aufräumen gegen den aktuellen Stand und die Protokolle früherer Aufräum-Durchgänge.
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
                ContentUnavailableView {
                    Label("Beobachtung nicht lesbar", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Die gespeicherte Beobachtung ließ sich nicht laden.")
                } actions: {
                    Button("Beobachtung löschen …", role: .destructive) { confirmsDelete = true }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func content(_ observation: InstallationObservation) -> some View {
        List {
            Section {
                ObservationHeader(observation: observation, observations: observations)
            }
            if observation.isActive {
                liveSections(observation)
            } else if let cleanup {
                finishedSections(observation, cleanup: cleanup)
            }
            Section {
                HStack {
                    Spacer()
                    Button(observation.isActive ? "Beobachtung abbrechen …" : "Beobachtung löschen …", role: .destructive) {
                        confirmsDelete = true
                    }
                    .disabled(observations.isBusy)
                }
            }
        }
        .listStyle(.inset)
    }

    /// Während der Beobachtung: was seit dem Start neu ist (gegen den jüngsten Scan), ohne Aufräumen.
    @ViewBuilder
    private func liveSections(_ observation: InstallationObservation) -> some View {
        if let current = appModel.monitoring.snapshot {
            let balance = ObservationBalance(baseline: observation.baseline, final: current)
            let presentation = ObservationBalancePresentation(
                balance: balance, attribution: ObservationAttribution(observationName: observation.name, newApps: balance.newApps)
            )
            BalanceSections(presentation: presentation, show: window.show)
        }
    }

    @ViewBuilder
    private func finishedSections(_ observation: InstallationObservation, cleanup: ObservationCleanupModel) -> some View {
        let presentation = ObservationBalancePresentation(balance: cleanup.balance, attribution: cleanup.attribution)
        Section {
            NoticeList(notices: notes(cleanup.balance))
            Text(verbatim: presentation.summary).font(.callout.weight(.medium))
        }
        if presentation.isEmpty {
            Section {
                Text(verbatim: presentation.emptyMessage)
                    .foregroundStyle(.secondary)
            }
        } else {
            BalanceSections(presentation: presentation, show: window.show)
            CleanupSection(cleanup: cleanup, actions: actions, observationID: observationID,
                           removeWithLeftovers: { window.requestRemoval(of: $0) }) { prepareCleanup(cleanup) }
        }
        if !observation.cleanups.isEmpty {
            CleanupRecordsSection(records: observation.cleanups)
        }
    }

    private func notes(_ balance: ObservationBalance) -> [String] {
        let names = { (sources: Set<SourceID>) in sources.sorted { $0.rawValue < $1.rawValue }.map(\.displayName) }
        return [
            ObservationTexts.failedSourcesNote(names(balance.failedSources)),
            ObservationTexts.limitationsNote(balance.limitations.map { "\($0.source.displayName): \($0.message)" }),
            ObservationTexts.firstDeliveredNote(names(balance.firstDeliveredSources)),
            ObservationTexts.userTCCNote,
        ].compactMap(\.self)
    }

    private func prepareCleanup(_ cleanup: ObservationCleanupModel) {
        Task {
            pendingPlan = await cleanup.preparePlan(scanner: appModel.leftovers, snapshot: appModel.monitoring.snapshot)
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

/// Kopf: Name, Zeitraum, Notiz; während der Beobachtung Status und „Beobachtung beenden“.
private struct ObservationHeader: View {
    let observation: InstallationObservation
    let observations: ObservationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: observation.name)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: period)
                .foregroundStyle(.secondary)
            if let note = observation.note {
                Text(verbatim: note)
            }
            if observation.isActive {
                TimelineView(.everyMinute) { context in
                    if let line = observations.statusLine(now: context.date) {
                        Text(verbatim: line).font(.callout)
                    }
                }
                Text("Installiere und starte jetzt das Tool. Neue Einträge erscheinen hier nach jedem Scan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Beobachtung beenden") { Task { await observations.finish() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(observations.isBusy)
                    if observations.phase == .finishing {
                        ProgressView().controlSize(.small)
                        Text("Abschließender Scan läuft …").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var period: String {
        let start = observation.startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let end = observation.finishedAt else { return String(localized: "Seit \(start)") }
        return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
            + " (\(ObservationTexts.duration(from: observation.startedAt, to: end)))"
    }
}

/// Abschnitte der Bilanz; jeder Eintrag führt zu seiner Detailansicht.
private struct BalanceSections: View {
    let presentation: ObservationBalancePresentation
    let show: (ChangeEvent) -> Void

    var body: some View {
        ForEach(presentation.sections) { section in
            Section {
                if let note = section.group.note {
                    HintLabel(text: note, systemImage: section.group.tone.systemImage, color: section.group.tone.color)
                }
                ForEach(section.rows) { row in
                    BalanceRow(row: row) { show(row.event) }
                }
            } header: {
                SectionHeader(title: section.group.title, trailing: "\(section.rows.count)")
            }
        }
    }
}

/// Ein Eintrag der Bilanz; ein geänderter Befehl zeigt sein Vorher/Nachher zum Aufklappen (#137).
private struct BalanceRow: View {
    let row: ObservationBalancePresentation.Row
    let show: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            summary
            if let change = row.event.commandChange {
                CommandChangeDisclosure(change: change)
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: row.event.kind.systemImage)
                .foregroundStyle(row.event.kind.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: row.title)
                    if let verdict = row.verdict {
                        VerdictBadge(verdict: verdict)
                    }
                }
                Text(verbatim: row.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(row.event.kind == .removed ? "Im Verlauf" : "Anzeigen", action: show)
                .buttonStyle(.link)
        }
        .accessibilityElement(children: .combine)
    }
}

/// „wahrscheinlich zugehörig“ bzw. „Zuordnung unsicher“ – als Text, mit Begründung im Tooltip.
private struct VerdictBadge: View {
    let verdict: ObservationAttribution.Verdict

    var body: some View {
        let tone: PresentationTone = verdict.isLikely ? .neutral : .warning
        Text(verbatim: verdict.isLikely ? ObservationTexts.likelyBadge : ObservationTexts.uncertainBadge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(verdict.isLikely ? Color.secondary : tone.color)
            .help(Text(verbatim: verdict.isLikely ? verdict.reason : verdict.reason + "\n" + ObservationTexts.uncertainExplanation))
    }
}

/// Auswahl der noch vorhandenen neuen Einträge und „Ausgewähltes entfernen …“.
private struct CleanupSection: View {
    @Bindable var cleanup: ObservationCleanupModel
    let actions: ActionRunner
    let observationID: UUID
    /// Öffnet das Entfernen-Blatt der App – dort sind auch die Reste einzeln wählbar.
    let removeWithLeftovers: (InstalledApp) -> Void
    let requestCleanup: () -> Void

    var body: some View {
        Section {
            if let offer = cleanup.offer {
                if offer.candidates.isEmpty {
                    Text("Keiner der neuen Einträge ist noch vorhanden.").foregroundStyle(.secondary)
                }
                ForEach(offer.candidates) { candidate in
                    HStack(alignment: .firstTextBaseline) {
                        SelectionToggleRow(candidate: candidate, selection: $cleanup.selection)
                            .disabled(cleanup.isPreparing)
                        if case .installedApp(let app) = candidate.subject, candidate.unavailableReason == nil {
                            Spacer(minLength: 8)
                            Button("Mit Resten entfernen …") { removeWithLeftovers(app) }
                                .buttonStyle(.link)
                                .disabled(!actions.canStart || cleanup.isPreparing)
                        }
                    }
                }
                if offer.goneCount > 0 {
                    InfoLabel(text: offer.goneCount == 1
                        ? String(localized: "1 neuer Eintrag ist nicht mehr (oder nicht mehr unverändert) vorhanden.")
                        : String(localized: "\(offer.goneCount) neue Einträge sind nicht mehr (oder nicht mehr unverändert) vorhanden."))
                        .font(.callout)
                }
                HStack(spacing: 8) {
                    Spacer()
                    if cleanup.isPreparing || actions.runningRecordID == ObservationCleanupPlan.id(for: observationID) {
                        ProgressView().controlSize(.small).accessibilityLabel("Aktion läuft")
                    }
                    Button("Ausgewähltes entfernen …", role: .destructive, action: requestCleanup)
                        .disabled(!cleanup.hasSelection || !actions.canStart || cleanup.isPreparing)
                }
            } else {
                Text("Erst nach dem nächsten Scan verfügbar.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Aufräumen")
        } footer: {
            Text("Angeboten wird, was von den neuen Einträgen heute noch existiert. Vorausgewählt ist nur, was wahrscheinlich zum Tool gehört; geänderte Einträge setzt Grantry nicht zurück. Von Apps geht nur das Programm selbst in den Papierkorb – Reste wählst du einzeln über „Mit Resten entfernen …“.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Frühere Aufräum-Durchgänge: Zeitpunkt, Erfolg je Eintrag mit Grund.
private struct CleanupRecordsSection: View {
    let records: [ObservationCleanupRecord]

    var body: some View {
        Section("Aufgeräumt") {
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(record.performedAt.formatted(date: .abbreviated, time: .shortened)) – "
                        + String(localized: "\(record.doneCount) von \(record.entries.count) erledigt"))
                        .font(.callout.weight(.medium))
                    ForEach(Array(record.entries.enumerated()), id: \.offset) { _, entry in
                        Label {
                            Text(verbatim: [entry.title, entry.reason].compactMap(\.self).joined(separator: ": "))
                                .font(.caption)
                        } icon: {
                            Image(systemName: entry.isDone ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(entry.isDone ? PresentationTone.positive.color : PresentationTone.warning.color)
                        }
                    }
                }
            }
        }
    }
}

extension SelectionToggleRow {
    /// Ein noch vorhandener neuer Eintrag einer Beobachtung; „Zuordnung unsicher“ mit Begründung im Tooltip.
    init(candidate: ObservationCleanupCandidate, selection: Binding<RemovalSelection>) {
        let verdict = candidate.verdict
        let detail = "\(candidate.detail()) — \(verdict.reason)"
        self.init(
            title: candidate.title, detail: detail,
            badge: verdict.isLikely ? nil : ObservationTexts.uncertainBadge,
            badgeHelp: ObservationTexts.uncertainExplanation,
            disabledReason: candidate.unavailableReason,
            accessibilityLabel: [candidate.title, detail, verdict.isLikely ? nil : ObservationTexts.uncertainBadge,
                                 candidate.unavailableReason].compactMap(\.self).joined(separator: ", "),
            isSelected: Binding(selection, id: candidate.id)
        )
    }
}
