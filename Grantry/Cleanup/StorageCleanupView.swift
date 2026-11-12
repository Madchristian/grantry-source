import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

/// Segment „Speicher“ im Lagebild (LB-4.3, #549; Entwurf LB-4.1, #547, Spec Speicher §2): Zustandszeile mit der
/// aufräumbaren Größe, Umschalter mit Scan-Fortschritt bzw. Stand als Spur, Banner für fehlenden Festplattenvollzugriff
/// (schon vor dem Scan) und das Ergebnis der letzten Aktion, im Panel Hinweise (nicht erfasste Ordner, keiner Kategorie
/// zugeordneter Platz #226, Neustart #229), Ausgänge je Eintrag, Kategorien nach Größe mit Spur des Anteils, aufklappbar
/// mit Häkchenzeilen, Time-Machine-Vorschläge mit eigenem Bestätigungsdialog (#227) und „Zuletzt aufgeräumt“; unten die
/// Aktionsleiste mit Scannen bzw. Abbrechen, Optionen, Umfang der Auswahl und „Aufräumen …“ mit Sammeldialog.
struct StorageCleanupView: View {
    @Bindable var model: StorageCleanupModel
    /// Öffnet die Einstellungen zum Festplattenvollzugriff; `nil`, wenn er nicht fehlt.
    var openFullDiskAccess: (() -> Void)?
    /// Kategorie, zu der die Liste springen soll (aus „Belegung“, #403); nach dem Sprung wieder `nil`. Ohne Scan startet
    /// er zuerst (nur lesend).
    @Binding var focusedCategoryID: String?
    let showSetup: () -> Void
    @State private var isConfirming: Bool?
    /// Aufgeklappte Kategorien.
    @State private var expanded: Set<String> = []
    @State private var showsUncovered = false
    @State private var timeMachineChange: TimeMachineChange?
    @State private var showsOptions = false

    var body: some View {
        CleanupBoard(head: StorageBoardMapping.head(reports: model.reports, timeMachine: model.timeMachine,
                                                    isScanning: model.phase == .scanning),
                     progress: StorageBoardMapping.progress(model.scanProgress.current, reports: model.reports)) {
            CleanupSegmentSwitcher()
        } banner: {
            banners
        } content: {
            content
        } bar: {
            actionBar
        }
        .actionConfirmation(for: $isConfirming, confirmation: { _ in
            StoragePresentation.confirmation(reports: model.reports, selection: model.selection)
        }) { _ in model.clean() }
        .actionConfirmation(for: $timeMachineChange, confirmation: { change in
            TimeMachinePresentation.confirmation(change, targets: timeMachineTargets(change))
        }) { model.changeTimeMachine($0) }
        .onChange(of: focusedCategoryID, initial: true) { _, id in
            // Noch nicht gescannt: erst lesen, dann springen.
            if id != nil, model.reports.isEmpty, model.phase == .idle { model.scan() }
        }
    }

    /// Der Zugriff fehlt (auch vor dem Scan), oder eine Kategorie meldet ihn als nötig.
    private var needsFullDiskAccess: Bool {
        openFullDiskAccess != nil || model.reports.contains { $0.status == .needsFullDiskAccess }
    }

    private var hasSelection: Bool {
        !StoragePresentation.selectedItems(in: model.reports, selection: model.selection).isEmpty
    }

    // MARK: - Banner

    @ViewBuilder
    private var banners: some View {
        if needsFullDiskAccess {
            PrerequisitesBanner(
                text: String(localized: "Ohne Festplattenvollzugriff erfasst Grantry geschützte Ordner nicht – ihre Größen fehlen in den Summen."),
                openFullDiskAccess: openFullDiskAccess, showSetup: showSetup
            )
        }
        if !model.lastOutcomes.isEmpty {
            InstrumentBanner(StoragePresentation.outcomeTitle(model.lastOutcomes),
                             message: StoragePresentation.summary(model.lastOutcomes),
                             tone: StoragePresentation.outcomeTone(model.lastOutcomes).statusTone)
        }
    }

    // MARK: - Aktionsleiste

    private var actionBar: some View {
        InstrumentActionBar(scope: StoragePresentation.selectionText(reports: model.reports, selection: model.selection),
                            runningText: model.phase == .cleaning ? String(localized: "Wird aufgeräumt …") : nil) {
            if model.phase == .scanning {
                Button("Abbrechen", action: model.cancel)
            } else {
                Button("Scannen", action: model.scan)
                    .disabled(model.scanProgress.isRunning || model.phase == .cleaning)
                    .help("Liest nur – entfernt nichts")
            }
            Button("Optionen …") { showsOptions = true }
                .popover(isPresented: $showsOptions) { StorageOptionsView(preferences: model.preferences) }
        } trailing: {
            Button(role: .destructive) { isConfirming = true } label: { Text("Aufräumen …") }
                .disabled(model.phase != .scanned || !hasSelection)
        }
    }

    // MARK: - Inhalt

    @ViewBuilder
    private var content: some View {
        if model.reports.isEmpty, model.phase == .idle {
            InstrumentEmptyState(symbol: "internaldrive", title: String(localized: "Noch nicht gescannt"),
                                 message: String(localized: "Der Scan startet nur, wenn du ihn anstößt. Gelöscht wird erst nach deiner Bestätigung."))
        } else {
            ScrollViewReader { proxy in
                CleanupFindingList {
                    StorageNotes(reports: model.reports, volume: model.volume, showsUncovered: $showsUncovered)
                    if !model.lastOutcomes.isEmpty {
                        StorageOutcomes(outcomes: model.lastOutcomes, reports: model.reports)
                    }
                    ForEach(model.sortedReports) { report in
                        categorySection(report)
                    }
                    if let report = model.timeMachine, !report.suggestions.isEmpty || report.failure != nil {
                        TimeMachineSuggestionsGroup(report: report, selection: $model.timeMachineSelection,
                                                    canChange: model.phase == .scanned) { timeMachineChange = $0 }
                    }
                    if !model.recentLog.isEmpty {
                        RecentLogGroup(entries: model.recentLog, logURL: model.logURL)
                    }
                }
                .onChange(of: model.reports.map(\.id), initial: true) { focus(using: proxy) }
                .onChange(of: focusedCategoryID) { focus(using: proxy) }
            }
        }
    }

    private func categorySection(_ report: StorageCategoryReport) -> some View {
        let timeMachineNote = model.timeMachine.flatMap {
            TimeMachinePresentation.categoryNote(report.id, in: $0.suggestions)
        }
        return StorageCategorySection(report: report, share: StoragePresentation.share(of: report, in: model.reports),
                                      summary: StorageBoardMapping.summary(report, timeMachineNote: timeMachineNote),
                                      selection: $model.selection,
                                      isExpanded: Binding(get: { expanded.contains(report.id) }, set: { isExpanded in
                                          if isExpanded { expanded.insert(report.id) } else { expanded.remove(report.id) }
                                      }),
                                      isLocked: model.phase == .cleaning)
            .id(report.id)
    }

    /// Springt zur gewünschten Kategorie und klappt sie auf, sobald ihr Bericht da ist; fehlt er nach dem Scan, entfällt
    /// der Sprung.
    private func focus(using proxy: ScrollViewProxy) {
        guard let id = focusedCategoryID else { return }
        guard model.reports.contains(where: { $0.id == id }) else {
            if model.phase == .scanned { focusedCategoryID = nil }
            return
        }
        expanded.insert(id)
        proxy.scrollTo(id, anchor: .top)
        focusedCategoryID = nil
    }

    private func timeMachineTargets(_ change: TimeMachineChange) -> [TimeMachineSuggestion] {
        TimeMachinePresentation.targets(of: change, in: model.timeMachine?.suggestions ?? [],
                                        selection: model.timeMachineSelection)
    }
}

/// Hinweise oben im Panel: „Nicht erfassbar: N Ordner“ mit den Pfaden zum Aufklappen, nach einem vollständigen Scan der
/// keiner Kategorie zugeordnete Platz (#226) und bei Agenten-Arbeitsordnern der Neustart (#229).
private struct StorageNotes: View {
    let reports: [StorageCategoryReport]
    let volume: VolumeUsage?
    @Binding var showsUncovered: Bool

    var body: some View {
        let paths = StoragePresentation.uncoveredPaths(reports)
        if let note = StoragePresentation.coverageNote(reports) {
            InstrumentNote(note, kind: .finding)
                .padding(.horizontal, InstrumentSpacing.group)
            DisclosureSection(String(localized: "Nicht erfasste Ordner"),
                              value: paths.count == 1 ? String(localized: "1 Ordner") : String(localized: "\(paths.count) Ordner"),
                              isExpanded: $showsUncovered, togglesOnHead: true) {
                Text("Nicht erfasste Ordner").font(InstrumentFont.label)
            } content: {
                ForEach(paths, id: \.self) { path in
                    Text(verbatim: StorageBoardMapping.abbreviated(path)).font(InstrumentFont.code)
                        .textSelection(.enabled)
                        .accessibilityReading(Text("Nicht erfasster Ordner"),
                                              value: Text(verbatim: StorageBoardMapping.abbreviated(path)))
                }
            }
            .padding(.horizontal, InstrumentSpacing.group)
        }
        if let unassigned = volume.flatMap({ StoragePresentation.unassignedNote(reports, volume: $0) }) {
            InstrumentNote(unassigned).padding(.horizontal, InstrumentSpacing.group)
        }
        if let restart = StoragePresentation.restartNote(reports) {
            InstrumentNote(restart).padding(.horizontal, InstrumentSpacing.group)
        }
    }
}

/// Ausgänge des letzten Aufräumens je Eintrag mit Zustandschip, Weg und Grund (Spec Speicher §2.5, § 11.4 d); danach der
/// Hinweis auf lokale Snapshots mit kopierbarem Befehl (Grantry führt ihn nicht aus).
private struct StorageOutcomes: View {
    let outcomes: [StorageCleanOutcome]
    let reports: [StorageCategoryReport]

    var body: some View {
        SelectionGroupHeader(title: String(localized: "Details"), count: outcomes.count)
        ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
            OutcomeRow(StorageBoardMapping.outcomeChip(outcome), target: StorageBoardMapping.outcomeTarget(outcome),
                       reason: StoragePresentation.outcomeReason(outcome))
        }
        if let note = TimeMachinePresentation.snapshotNote(after: outcomes, reports: reports) {
            DetailItem(InstrumentRowContent(symbol: "clock.arrow.circlepath", title: String(localized: "Lokale Snapshots"),
                                            detail: note.text)) {
                DetailEntry(String(localized: "Befehl"), value: note.command, isCode: true)
            } actions: {
                Button("Befehl kopieren") { copy(note.command) }
            }
            .padding(.horizontal, InstrumentSpacing.group)
        }
    }
}

/// Eine Kategorie (§ 11.4 c): Kopf mit Satz, Status, Risiko, Größe und Spur des Anteils als Aufklapp-Knopf; aufgeklappt
/// die Einträge als Häkchenzeilen, Einträge ohne Häkchen mit Verweis (Befehl kopieren, Im Finder zeigen). Während einer
/// Aktion bleiben die Häkchen sichtbar, gesperrt und blass (e).
private struct StorageCategorySection: View {
    let report: StorageCategoryReport
    let share: Double?
    let summary: String
    @Binding var selection: Set<String>
    @Binding var isExpanded: Bool
    let isLocked: Bool

    var body: some View {
        let risk = StorageBoardMapping.risk(report.category.risk)
        let status = StorageBoardMapping.status(report.status)
        DisclosureSection(report.category.title,
                          value: StorageCategoryHead.spokenValue(size: report.sizeText, share: share, risk: risk,
                                                                 status: status, summary: summary),
                          isExpanded: $isExpanded, togglesOnHead: true) {
            StorageCategoryHead(title: report.category.title, summary: summary, risk: risk, status: status,
                                size: report.sizeText, share: share)
        } content: {
            ForEach(report.items) { item in
                itemRow(item)
            }
        }
        .padding(.leading, InstrumentSpacing.group)
    }

    @ViewBuilder
    private func itemRow(_ item: StorageItem) -> some View {
        if item.isSelectable {
            SelectionCheckRow(item.title, detail: StorageBoardMapping.detail(item), size: item.sizeText,
                              isOn: isSelected(item))
                .disabled(isLocked)
        } else if let hint = item.hint {
            ReportRow(symbol: "terminal", title: item.title, detail: item.detail ?? "", size: item.sizeText) {
                Button("Befehl kopieren") { copy(hint) }
                    .accessibilityLabel(Text("Befehl für \(item.title) kopieren"))
            }
        } else {
            ReportRow(symbol: "lock", title: item.title, detail: item.detail ?? "", size: item.sizeText) {
                if let path = item.path {
                    Button("Im Finder zeigen") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                        .accessibilityLabel(Text("\(item.title) im Finder zeigen"))
                }
            }
        }
    }

    private func isSelected(_ item: StorageItem) -> Binding<Bool> {
        Binding(get: { selection.contains(item.id) },
                set: { if $0 { selection.insert(item.id) } else { selection.remove(item.id) } })
    }
}

/// „Time-Machine-Vorschläge“ (#227): Ordner, die sich neu erzeugen oder laden lassen, mit Status, Größe und Risiko;
/// vorausgewählt nur Risiko „gering“. Die Knöpfe ändern nur gewählte Ordner, deren Status die Änderung betrifft.
private struct TimeMachineSuggestionsGroup: View {
    let report: TimeMachineReport
    @Binding var selection: Set<String>
    let canChange: Bool
    let confirm: (TimeMachineChange) -> Void

    var body: some View {
        SelectionGroupHeader(title: String(localized: "Time-Machine-Vorschläge"), count: report.suggestions.count)
        if let failure = report.failure {
            InstrumentNote(String(localized: "Status nicht lesbar: \(failure)"), kind: .critical)
                .padding(.horizontal, InstrumentSpacing.group)
        }
        ForEach(report.suggestions) { suggestion in
            SelectionCheckRow(suggestion.candidate.title,
                              detail: "\(StorageBoardMapping.abbreviated(suggestion.candidate.path)) · "
                                  + TimeMachinePresentation.stateText(suggestion.state),
                              size: suggestion.sizeText, isOn: isSelected(suggestion),
                              hint: StorageBoardMapping.risk(suggestion.candidate.risk))
                .disabled(!canChange || suggestion.state == .unknown)
        }
        HStack(spacing: InstrumentSpacing.group) {
            Button("Aus Time Machine ausnehmen …") { confirm(.exclude) }
                .disabled(!canChange || targets(.exclude).isEmpty)
            Button("Wieder sichern …") { confirm(.include) }
                .disabled(!canChange || targets(.include).isEmpty)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, InstrumentSpacing.group)
        InstrumentNote(String(localized: "Lässt sich neu erzeugen oder herunterladen. Grantry ändert nur die Sicherung, nicht die Ordner."))
            .padding(.horizontal, InstrumentSpacing.group)
    }

    private func targets(_ change: TimeMachineChange) -> [TimeMachineSuggestion] {
        TimeMachinePresentation.targets(of: change, in: report.suggestions, selection: selection)
    }

    private func isSelected(_ suggestion: TimeMachineSuggestion) -> Binding<Bool> {
        Binding(get: { selection.contains(suggestion.id) },
                set: { if $0 { selection.insert(suggestion.id) } else { selection.remove(suggestion.id) } })
    }
}

/// „Zuletzt aufgeräumt“ mit Zustandschip je Eintrag, bei Übersprungenem und Fehlgeschlagenem mit Grund, und Sprung zum
/// Protokoll.
private struct RecentLogGroup: View {
    let entries: [CleanupLogEntry]
    let logURL: URL

    var body: some View {
        SelectionGroupHeader(title: String(localized: "Zuletzt aufgeräumt"), count: entries.count)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            OutcomeRow(StorageBoardMapping.outcomeChip(entry.outcome), target: StorageBoardMapping.logTarget(entry),
                       reason: StoragePresentation.outcomeReason(entry.outcome))
                .help(Text(verbatim: StoragePresentation.resultText(entry.outcome)))
        }
        Button("Protokoll im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
            .buttonStyle(.link)
            .font(InstrumentFont.label)
            .padding(.horizontal, InstrumentSpacing.group)
    }
}

/// Legt einen Befehl in die Zwischenablage; Grantry führt ihn nicht aus.
private func copy(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
}

/// Code-Wurzeln und Altersgrenze der Projektsuche; wirken beim nächsten Scan.
private struct StorageOptionsView: View {
    let preferences: StoragePreferences
    @State private var roots: [String] = []
    @State private var days = StoragePreferences.defaultMinimumAgeDays

    var body: some View {
        StorageOptionsContent(roots: roots, days: $days, remove: remove, addRoot: addRoot)
            .onChange(of: days) { _, value in preferences.minimumAgeDays = value }
            .onAppear {
                roots = preferences.codeRoots
                days = preferences.minimumAgeDays
            }
    }

    private func remove(_ root: String) {
        roots.removeAll { $0 == root }
        preferences.codeRoots = roots
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url, !roots.contains(url.path) else { return }
        roots.append(url.path)
        preferences.codeRoots = roots
    }
}

/// Reines Layout: auch in Vorschauen ohne Zugriff auf echte Einstellungen verwendbar.
private struct StorageOptionsContent: View {
    let roots: [String]
    @Binding var days: Int
    let remove: (String) -> Void
    let addRoot: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
            Text("Code-Ordner")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if roots.isEmpty {
                Text("Keine Code-Ordner ausgewählt.")
                    .foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                        ForEach(roots, id: \.self) { root in
                            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                                Text(verbatim: (root as NSString).abbreviatingWithTildeInPath)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(root)
                                    .accessibilityLabel(Text(verbatim: root))
                                Button("Entfernen") { remove(root) }
                                    .accessibilityLabel(Text("\((root as NSString).abbreviatingWithTildeInPath) entfernen"))
                                    .fixedSize()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, InstrumentSpacing.group)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            }
            Button("Ordner hinzufügen …", action: addRoot)
            Divider()
            Stepper(value: $days, in: 1...365) {
                Text("Nur Projekte älter als \(days) Tage")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(InstrumentSpacing.bar)
        .frame(width: 380, alignment: .leading)
    }
}
