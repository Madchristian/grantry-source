import GrantryCharts
import ManagerKit
import SwiftUI

/// Segment „Prozesse“ (#221) im Lagebild (LB-4.4, #550; Entwurf LB-4.1, #547, Spec 2026-11-10 § 11.4): Zustandszeile mit
/// Speicherstand, Umschalter mit Stand des Scans, Banner (fehlender Festplattenvollzugriff, Prozesse nicht lesbar, Ergebnis
/// des letzten Beendens), verwaiste Agenten-Bäume (aufklappbar) und gebootete Simulatoren als Häkchenzeilen, Aktionsleiste
/// unten. Sammeldialog vor dem Beenden und – für Überlebende des SIGTERM – eine zweite Bestätigung für SIGKILL. Fehlt der
/// Festplattenvollzugriff, sagt `PrerequisitesBanner`, dass die Prozessliste davon nicht betroffen ist (#226).
struct ProcessCleanupView: View {
    @Bindable var model: ProcessCleanupModel
    /// Öffnet die Einstellungen zum Festplattenvollzugriff; `nil`, wenn er nicht fehlt.
    var openFullDiskAccess: (() -> Void)?
    let showSetup: () -> Void
    @State private var isConfirming: Bool?
    @State private var isConfirmingForce: Bool?
    /// Aufgeklappte Agenten-Bäume (`AgentProcessTree.id`); zu Beginn alle zu.
    @State private var expandedTrees: Set<String> = []

    var body: some View {
        CleanupBoard(head: ProcessCleanupBoardMapping.head(model), progress: ProcessCleanupBoardMapping.progress(model)) {
            CleanupSegmentSwitcher()
        } banner: {
            banners
        } content: {
            content
        } bar: {
            actionBar
        }
        .actionConfirmation(for: $isConfirming, confirmation: { _ in
            ProcessCleanupPresentation.confirmation(trees: model.selectedTrees, simulators: model.selectedSimulators)
        }) { _ in model.clean() }
        .actionConfirmation(for: $isConfirmingForce, confirmation: { _ in
            ProcessCleanupPresentation.forceConfirmation(model.forceOffer)
        }) { _ in model.forceTerminate() }
    }

    private var isBusy: Bool { model.phase == .scanning || model.phase == .cleaning }

    // MARK: - Banner

    @ViewBuilder
    private var banners: some View {
        if openFullDiskAccess != nil {
            PrerequisitesBanner(
                text: String(localized: "Festplattenvollzugriff fehlt. Die Prozessliste ist davon nicht betroffen, unter „Speicher“ bleiben geschützte Ordner aber unerfasst."),
                openFullDiskAccess: openFullDiskAccess, showSetup: showSetup
            )
        }
        if let error = model.scanError {
            InstrumentBanner(String(localized: "Prozesse nicht lesbar"), message: error, tone: .critical)
        }
        if let result = ProcessCleanupBoardMapping.result(model.lastOutcomes) {
            InstrumentBanner(result.title, message: result.message, tone: result.tone)
        }
    }

    // MARK: - Funde

    @ViewBuilder
    private var content: some View {
        if let overview = model.overview, showsList(overview) {
            CleanupFindingList {
                outcomes
                findings(overview)
            }
        } else if model.overview != nil {
            InstrumentEmptyState(symbol: "checkmark.circle", title: String(localized: "Nichts gefunden"),
                                 message: String(localized: "Keine verwaisten Agenten-Prozesse und keine gebooteten Simulatoren."))
        } else if model.phase == .scanning {
            InstrumentEmptyState(symbol: "magnifyingglass", title: String(localized: "Prozesse werden gelesen"),
                                 message: String(localized: "Grantry liest Prozesse und gebootete Simulatoren – beendet nichts."))
        } else {
            InstrumentEmptyState(symbol: "memorychip", title: String(localized: "Noch nicht gescannt"),
                                 message: String(localized: "Der Scan startet nur, wenn du ihn anstößt. Beendet wird erst nach deiner Bestätigung."))
        }
    }

    /// Liste statt „Nichts gefunden“, sobald es Posten, Ausgänge oder Hinweise gibt.
    private func showsList(_ overview: ProcessOverview) -> Bool {
        !overview.agentTrees.orphans.isEmpty || !overview.simulators.isEmpty || overview.simulatorError != nil
            || overview.agentTrees.inUseCount > 0 || !model.lastOutcomes.isEmpty
    }

    /// Ausgänge des letzten Beendens je Posten (§ 11.4 d).
    @ViewBuilder
    private var outcomes: some View {
        if !model.lastOutcomes.isEmpty {
            SelectionGroupHeader(title: String(localized: "Details"), count: model.lastOutcomes.count)
            ForEach(Array(model.lastOutcomes.enumerated()), id: \.offset) { _, outcome in
                OutcomeRow(ProcessCleanupBoardMapping.outcomeStatus(outcome), target: outcome.title,
                           reason: ProcessCleanupPresentation.outcomeReason(outcome))
            }
        }
    }

    @ViewBuilder
    private func findings(_ overview: ProcessOverview) -> some View {
        if let error = overview.simulatorError {
            InstrumentNote(String(localized: "Simulatoren nicht lesbar: \(error)"), kind: .critical)
        }
        let trees = overview.agentTrees.orphans
        if !trees.isEmpty {
            SelectionGroupHeader(title: String(localized: "Verwaiste Agenten-Prozesse"), count: trees.count,
                                 size: ProcessCleanupPresentation.memoryText(of: trees), finding: true)
            ForEach(trees) { tree in
                AgentTreeSection(tree: tree, isSelected: binding(ProcessCleanupModel.treeSelectionID(tree)),
                                 isExpanded: expansion(tree.id), isLocked: isBusy)
            }
        }
        if let note = ProcessCleanupPresentation.inUseNote(overview.agentTrees.inUseCount) {
            InstrumentNote(note)
        }
        if !overview.simulators.isEmpty {
            SelectionGroupHeader(title: String(localized: "Gebootete Simulatoren"), count: overview.simulators.count,
                                 size: ProcessCleanupPresentation.memoryText(of: [], simulators: overview.simulators))
            ForEach(overview.simulators) { simulator in
                SelectionCheckRow(simulator.title, detail: ProcessCleanupPresentation.detail(simulator, now: .now),
                                  size: ProcessCleanupPresentation.sizeText(simulator),
                                  isOn: binding(ProcessCleanupModel.simulatorSelectionID(simulator)))
                    .disabled(isBusy)
            }
        }
    }

    // MARK: - Aktionsleiste

    private var actionBar: some View {
        InstrumentActionBar(
            scope: ProcessCleanupPresentation.selectionScope(trees: model.selectedTrees,
                                                             simulators: model.selectedSimulators),
            runningText: model.phase == .cleaning ? String(localized: "Wird beendet …") : nil
        ) {
            Button("Scannen", action: model.scan)
                .disabled(model.scanProgress.isRunning || model.phase == .cleaning)
                .help("Liest nur – beendet nichts")
        } trailing: {
            if !model.forceOffer.isEmpty {
                Button("Sofort beenden (SIGKILL) …") { isConfirmingForce = true }
                    .disabled(model.phase != .scanned)
            }
            Button(role: .destructive) { isConfirming = true } label: { Text("Beenden …") }
                .disabled(model.phase != .scanned || (model.selectedTrees.isEmpty && model.selectedSimulators.isEmpty))
        }
    }

    // MARK: - Bindungen

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selection.contains(id) },
                set: { if $0 { model.selection.insert(id) } else { model.selection.remove(id) } })
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedTrees.contains(id) },
                set: { if $0 { expandedTrees.insert(id) } else { expandedTrees.remove(id) } })
    }
}

/// Ein Agenten-Baum (§ 11.4 g): Häkchenzeile mit Name, Arbeitsordner, Alter, Prozesszahl und Speicher; aufgeklappt die
/// Prozesse eingerückt (nur Programm- und Skriptname, nie die Befehlszeile).
private struct AgentTreeSection: View {
    let tree: AgentProcessTree
    let isSelected: Binding<Bool>
    let isExpanded: Binding<Bool>
    let isLocked: Bool

    var body: some View {
        let memory = ProcessCleanupPresentation.memoryText(tree.memoryBytes)
        DisclosureSection(tree.title, value: memory, isExpanded: isExpanded) {
            SelectionCheckRow(tree.title, detail: ProcessCleanupPresentation.detail(tree, now: .now), size: memory,
                              isOn: isSelected)
                .disabled(isLocked)
        } content: {
            ForEach(tree.members, id: \.pid) { member in
                DisclosureMemberRow(member.label, value: ProcessCleanupPresentation.memberValue(member))
            }
        }
    }
}
