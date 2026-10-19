import ManagerKit
import SwiftUI

/// Segment „Prozesse“ (#221): Speicherstatus, verwaiste Agenten-Bäume und gebootete Simulatoren auf Knopfdruck,
/// Auswahl, Sammeldialog vor dem Beenden und – für Überlebende des SIGTERM – eine zweite Bestätigung für SIGKILL. Fehlt
/// der Festplattenvollzugriff, sagt `PrerequisitesBanner`, dass die Prozessliste davon nicht betroffen ist (#226).
struct ProcessCleanupView: View {
    @Bindable var model: ProcessCleanupModel
    /// Öffnet die Einstellungen zum Festplattenvollzugriff; `nil`, wenn er nicht fehlt.
    var openFullDiskAccess: (() -> Void)?
    let showSetup: () -> Void
    @State private var isConfirming: Bool?
    @State private var isConfirmingForce: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if openFullDiskAccess != nil {
                PrerequisitesBanner(
                    text: String(localized: "Festplattenvollzugriff fehlt. Die Prozessliste ist davon nicht betroffen, unter „Speicher“ bleiben geschützte Ordner aber unerfasst."),
                    openFullDiskAccess: openFullDiskAccess, showSetup: showSetup
                )
                .padding([.horizontal, .bottom], 12)
            }
            if let overview = model.overview {
                Text(verbatim: ProcessCleanupPresentation.statusLine(overview.memory))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 12)
            }
            notices
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .actionConfirmation(for: $isConfirming, confirmation: { _ in
            ProcessCleanupPresentation.confirmation(trees: model.selectedTrees, simulators: model.selectedSimulators)
        }) { _ in model.clean() }
        .actionConfirmation(for: $isConfirmingForce, confirmation: { _ in
            ProcessCleanupPresentation.forceConfirmation(model.forceOffer)
        }) { _ in model.forceTerminate() }
    }

    private var isBusy: Bool { model.phase == .scanning || model.phase == .cleaning }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Scannen", action: model.scan)
                .disabled(isBusy)
                .help("Liest nur – beendet nichts")
            if isBusy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.phase == .scanning ? "Scan läuft" : "Beenden läuft")
            }
            Spacer(minLength: 8)
            if !model.forceOffer.isEmpty {
                Button("Sofort beenden (SIGKILL) …") { isConfirmingForce = true }
                    .disabled(model.phase != .scanned)
            }
            Button(role: .destructive) { isConfirming = true } label: { Text("Beenden …") }
                .disabled(model.phase != .scanned || (model.selectedTrees.isEmpty && model.selectedSimulators.isEmpty))
        }
        .padding(12)
    }

    @ViewBuilder
    private var notices: some View {
        let texts = [
            model.scanError.map { "Prozesse nicht lesbar: \($0)" },
            model.overview?.simulatorError.map { "Simulatoren nicht lesbar: \($0)" },
            model.overview.flatMap { ProcessCleanupPresentation.inUseNote($0.agentTrees.inUseCount) },
            model.lastOutcomes.isEmpty ? nil : ProcessCleanupPresentation.summary(model.lastOutcomes),
        ].compactMap(\.self)
        if !texts.isEmpty || !model.lastOutcomes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                NoticeList(notices: texts)
                if !model.lastOutcomes.isEmpty { OutcomeList(outcomes: model.lastOutcomes) }
            }
            .padding([.horizontal, .bottom], 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let overview = model.overview {
            if overview.agentTrees.orphans.isEmpty, overview.simulators.isEmpty {
                ContentUnavailableView("Nichts gefunden", systemImage: "checkmark.circle",
                                       description: Text("Keine verwaisten Agenten-Prozesse und keine gebooteten Simulatoren."))
            } else {
                List {
                    if !overview.agentTrees.orphans.isEmpty {
                        Section("Verwaiste Agenten-Prozesse") {
                            ForEach(overview.agentTrees.orphans) { tree in
                                AgentTreeRow(tree: tree, isSelected: binding(ProcessCleanupModel.treeSelectionID(tree)),
                                             isLocked: isBusy)
                            }
                        }
                    }
                    if !overview.simulators.isEmpty {
                        Section("Gebootete Simulatoren") {
                            ForEach(overview.simulators) { simulator in
                                Toggle(isOn: binding(ProcessCleanupModel.simulatorSelectionID(simulator))) {
                                    VStack(alignment: .leading) {
                                        Text(verbatim: simulator.title)
                                        Text(verbatim: ProcessCleanupPresentation.subtitle(simulator, now: .now))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(isBusy)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        } else if model.phase == .scanning {
            Spacer()
        } else {
            ContentUnavailableView(
                "Noch nicht gescannt", systemImage: "memorychip",
                description: Text("Der Scan startet nur, wenn du ihn anstößt. Beendet wird erst nach deiner Bestätigung.")
            )
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selection.contains(id) },
                set: { if $0 { model.selection.insert(id) } else { model.selection.remove(id) } })
    }
}

/// Ein Agenten-Baum: Auswahl mit Name, Arbeitsordner, Alter, Prozesszahl und Speicher; aufgeklappt die Prozesse (nur
/// Programm- und Skriptname, nie die Befehlszeile).
private struct AgentTreeRow: View {
    let tree: AgentProcessTree
    let isSelected: Binding<Bool>
    let isLocked: Bool

    var body: some View {
        DisclosureGroup {
            ForEach(tree.members, id: \.pid) { member in
                HStack {
                    Text(verbatim: member.label)
                    Spacer()
                    Text(verbatim: "PID \(member.pid)").foregroundStyle(.secondary).monospacedDigit()
                    Text(verbatim: member.memoryBytes.map(ProcessCleanupPresentation.memoryText) ?? "–")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
            }
        } label: {
            Toggle(isOn: isSelected) {
                VStack(alignment: .leading) {
                    Text(verbatim: tree.title)
                    Text(verbatim: ProcessCleanupPresentation.subtitle(tree, now: .now))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(isLocked)
        }
    }
}

/// Ausgänge des letzten Beendens je Posten.
private struct OutcomeList: View {
    let outcomes: [ProcessCleanupOutcome]

    var body: some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                    Text(verbatim: "\(outcome.title): \(StoragePresentation.resultText(outcome.logEntry))")
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }
}
