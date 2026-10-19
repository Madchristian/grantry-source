import AppKit
import ManagerKit
import SwiftUI

/// Segment „Speicher“ (Spec Speicher §2): Knopf „Scannen“, Kategorien nach Größe mit Risiko und Status, aufklappbar
/// mit Einzelauswahl, Sammeldialog vor dem Aufräumen, Ergebnis und „Zuletzt aufgeräumt“. Fehlt der
/// Festplattenvollzugriff, weist `PrerequisitesBanner` schon vor dem Scan darauf hin; nach dem Scan nennen Hinweise
/// nicht erfassbare Ordner und den keiner Kategorie zugeordneten Platz (#226).
struct StorageCleanupView: View {
    @Bindable var model: StorageCleanupModel
    /// Öffnet die Einstellungen zum Festplattenvollzugriff; `nil`, wenn er nicht fehlt.
    var openFullDiskAccess: (() -> Void)?
    let showSetup: () -> Void
    @State private var isConfirming: Bool?
    @State private var showsOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if needsFullDiskAccess {
                PrerequisitesBanner(
                    text: String(localized: "Ohne Festplattenvollzugriff erfasst Grantry geschützte Ordner nicht – ihre Größen fehlen in den Summen."),
                    openFullDiskAccess: openFullDiskAccess, showSetup: showSetup
                )
                .padding([.horizontal, .bottom], 12)
            }
            coverage
            if !model.lastOutcomes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    NoticeList(notices: [StoragePresentation.summary(model.lastOutcomes)])
                    OutcomeDetails(outcomes: model.lastOutcomes)
                }
                .padding([.horizontal, .bottom], 12)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .actionConfirmation(for: $isConfirming, confirmation: { _ in
            StoragePresentation.confirmation(reports: model.reports, selection: model.selection)
        }) { _ in model.clean() }
    }

    /// Zeile in „Zuletzt aufgeräumt“; bei Übersprungenem und Fehlgeschlagenem mit Grund.
    private func recentLogRow(_ entry: CleanupLogEntry) -> some View {
        let isRemoved = entry.outcome.result == .removed
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            OutcomeMarker(result: entry.outcome.result)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(entry.date.formatted(date: .abbreviated, time: .shortened)) – \(abbreviatedTarget(entry.outcome.target))")
                if !isRemoved {
                    Text(verbatim: StoragePresentation.resultText(entry.outcome)).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .help(Text(verbatim: StoragePresentation.resultText(entry.outcome)))
    }

    /// Der Zugriff fehlt (auch vor dem Scan), oder eine Kategorie meldet ihn als nötig.
    private var needsFullDiskAccess: Bool {
        openFullDiskAccess != nil || model.reports.contains { $0.status == .needsFullDiskAccess }
    }

    /// „Nicht erfassbar: N Ordner“ mit den Pfaden zum Aufklappen und, nach einem vollständigen Scan, der keiner
    /// Kategorie zugeordnete Platz.
    @ViewBuilder
    private var coverage: some View {
        let paths = StoragePresentation.uncoveredPaths(model.reports)
        let unassigned = model.volume.flatMap { StoragePresentation.unassignedNote(model.reports, volume: $0) }
        if !paths.isEmpty || unassigned != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let note = StoragePresentation.coverageNote(model.reports) {
                    NoticeList(notices: [note])
                    DisclosureGroup("Nicht erfasste Ordner") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(paths, id: \.self) { Text(verbatim: abbreviatedTarget($0)).textSelection(.enabled) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
                if let unassigned {
                    Text(verbatim: unassigned).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
    }

    private var hasSelection: Bool {
        !StoragePresentation.selectedItems(in: model.reports, selection: model.selection).isEmpty
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Scannen", action: model.scan)
                .disabled(model.phase == .scanning || model.phase == .cleaning)
                .help("Liest nur – entfernt nichts")
            if model.phase == .scanning {
                ProgressView().controlSize(.small).accessibilityLabel("Scan läuft")
                Button("Abbrechen", action: model.cancel)
            }
            Button("Optionen …") { showsOptions = true }
                .popover(isPresented: $showsOptions) { StorageOptionsView(preferences: model.preferences) }
            Spacer(minLength: 8)
            if model.phase == .cleaning {
                ProgressView().controlSize(.small).accessibilityLabel("Aufräumen läuft")
            }
            Button(role: .destructive) { isConfirming = true } label: { Text("Aufräumen …") }
                .disabled(model.phase != .scanned || !hasSelection)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if model.reports.isEmpty, model.phase == .idle {
            ContentUnavailableView(
                "Noch nicht gescannt", systemImage: "internaldrive",
                description: Text("Der Scan startet nur, wenn du ihn anstößt. Gelöscht wird erst nach deiner Bestätigung.")
            )
        } else {
            List {
                ForEach(model.sortedReports) { report in
                    StorageCategoryRow(report: report, selection: $model.selection,
                                       isLocked: model.phase == .cleaning)
                }
                if !model.recentLog.isEmpty {
                    Section("Zuletzt aufgeräumt") {
                        ForEach(Array(model.recentLog.enumerated()), id: \.offset) { _, entry in
                            recentLogRow(entry)
                        }
                        Button("Protokoll im Finder zeigen") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.logURL])
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// Ausgänge des letzten Aufräumens je Eintrag: Ziel, Weg und Ergebnis mit Grund (Spec Speicher §2.5).
private struct OutcomeDetails: View {
    let outcomes: [StorageCleanOutcome]

    var body: some View {
        DisclosureGroup("Details") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            OutcomeMarker(result: outcome.result)
                            Text(verbatim: "\(abbreviatedTarget(outcome.target)) (\(StoragePresentation.methodText(outcome.method))): "
                                 + StoragePresentation.resultText(outcome))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
        .font(.caption)
    }
}

/// Symbol für das Ergebnis eines Eintrags, mit Ergebnis als Bedienungshilfe-Text.
private struct OutcomeMarker: View {
    let result: StorageCleanOutcome.Result

    var body: some View {
        switch result {
        case .removed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("aufgeräumt")
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary).accessibilityLabel("übersprungen")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("fehlgeschlagen")
        }
    }
}

/// Pfade mit `~` statt des Benutzerordners; Befehlszeilen bleiben unverändert.
private func abbreviatedTarget(_ target: String) -> String { (target as NSString).abbreviatingWithTildeInPath }

/// Eine Kategorie: Kopfzeile mit Größe, Risiko und Status; aufgeklappt die Einträge.
private struct StorageCategoryRow: View {
    let report: StorageCategoryReport
    @Binding var selection: Set<String>
    let isLocked: Bool

    var body: some View {
        DisclosureGroup {
            ForEach(report.items) { item in
                itemRow(item)
            }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(verbatim: report.category.title)
                    Text(verbatim: report.category.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let status = StoragePresentation.statusText(report.status) {
                    Text(verbatim: status).font(.caption).foregroundStyle(.orange)
                }
                Text(verbatim: StoragePresentation.riskText(report.category.risk)).font(.caption)
                    .padding(.horizontal, 6).background(.quaternary, in: Capsule())
                Text(verbatim: report.sizeText).monospacedDigit()
            }
        }
    }

    private func itemRow(_ item: StorageItem) -> some View {
        HStack {
            if item.isSelectable {
                Toggle(isOn: isSelected(item)) { itemLabel(item) }
                    .disabled(isLocked)
            } else {
                itemLabel(item)
            }
            Spacer()
            Text(verbatim: item.sizeText).foregroundStyle(.secondary)
            if let hint = item.hint {
                Button("Befehl kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hint, forType: .string)
                }
                .buttonStyle(.link)
                .accessibilityLabel(Text("Befehl für \(item.title) kopieren"))
            } else if let path = item.path, !item.isSelectable {
                Button("Im Finder zeigen") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                    .buttonStyle(.link)
                    .accessibilityLabel(Text("\(item.title) im Finder zeigen"))
            }
        }
    }

    /// Titel, darunter ggf. die Zusatzzeile („Zuletzt benutzt …“, „Wird gerade benutzt von …“).
    private func itemLabel(_ item: StorageItem) -> some View {
        VStack(alignment: .leading) {
            Text(verbatim: item.title)
            if let detail = item.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func isSelected(_ item: StorageItem) -> Binding<Bool> {
        Binding(get: { selection.contains(item.id) },
                set: { if $0 { selection.insert(item.id) } else { selection.remove(item.id) } })
    }
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Code-Ordner")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if roots.isEmpty {
                Text("Keine Code-Ordner ausgewählt.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(roots, id: \.self) { root in
                            HStack(alignment: .top, spacing: 12) {
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
                    .padding(.trailing, 8)
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
        .padding(20)
        .frame(width: 380, alignment: .leading)
    }
}
