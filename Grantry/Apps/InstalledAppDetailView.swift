import AppKit
import ManagerKit
import SwiftUI

/// Eine App im Detail (Spec v3 §5): Angaben aus dem Kit (`InstalledAppDetail`) samt Hinweis zur Signaturprüfung, Pfad
/// mit „Im Finder zeigen“, Prüfhinweise sowie Berechtigungen und Autostart-Einträge mit Sprung in ihre Bereiche;
/// „App entfernen …“ und „Reste anzeigen“ öffnen das Entfernen-Blatt.
struct InstalledAppDetailView: View {
    let detail: InstalledAppDetail
    let presentation: PresentationSnapshot
    let actions: ActionRunner
    @Environment(MainWindowModel.self) private var window

    private var app: InstalledApp { detail.app }

    var body: some View {
        Form {
            header
            actionSection
            factsSection
            placeSection
            findingsSection
            grantsSection
            autostartSection
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                AppIconView(app: app.identity, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: app.name)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(verbatim: app.originDetail)
                        .foregroundStyle(.secondary)
                    RecordBadgesRow(badges: presentation.badges.badges(for: app.id))
                }
            }
        }
    }

    /// „App entfernen …“ (Spec v3 §3, Einstiegspunkt 1) und „Reste anzeigen“; beide öffnen nur das Entfernen-Blatt.
    private var actionSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("App entfernen …") { window.requestRemoval(of: app) }
                Button("Reste anzeigen") { window.requestRemoval(of: app, mode: .leftovers) }
                if actions.runningRecordID == app.id {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Aktion läuft")
                }
            }
            .disabled(actions.runningRecordID == app.id)
        }
    }

    private var factsSection: some View {
        Section("Angaben") {
            ForEach(detail.facts) { fact in
                LabeledContent {
                    HStack(spacing: 4) {
                        if let tone = fact.tone {
                            Image(systemName: tone.systemImage).foregroundStyle(tone.color)
                        }
                        Text(verbatim: fact.value).textSelection(.enabled)
                    }
                } label: {
                    Text(verbatim: fact.label)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: fact.accessibilityLabel))
            }
            if let note = detail.signingNote {
                HintLabel(text: note, systemImage: "clock", color: .secondary)
            }
        }
    }

    private var placeSection: some View {
        Section("Ort") {
            LabeledContent("Pfad") { PathText(path: detail.pathText) }
            Button("Im Finder zeigen") { app.revealInFinder() }
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        if !detail.findings.isEmpty {
            Section("Hinweise") { RecordHints(findings: detail.findings) }
        }
    }

    @ViewBuilder
    private var grantsSection: some View {
        if !detail.grants.isEmpty {
            Section("Berechtigungen") {
                ForEach(detail.grants) { grant in
                    Button { window.show(grant) } label: {
                        LabeledContent {
                            Text(verbatim: grant.authValue.displayName.capitalizedFirst)
                                .foregroundStyle(grant.authValue.tone.color)
                        } label: {
                            Text(verbatim: grant.serviceName)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("In „Berechtigungen“ zeigen")
                    .accessibilityHint(Text("Zeigt die Berechtigung im Bereich „Berechtigungen“."))
                }
            }
        }
    }

    @ViewBuilder
    private var autostartSection: some View {
        if !detail.autostartItems.isEmpty {
            Section("Autostart") {
                ForEach(detail.autostartItems) { item in
                    Button { window.show(item) } label: {
                        AutostartItemRow(item: item, badges: presentation.badges.badges(for: item.id))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("In „Autostart“ zeigen")
                    .accessibilityHint(Text("Zeigt den Eintrag im Bereich „Autostart“."))
                }
            }
        }
    }
}

extension InstalledApp {
    /// Zeigt das Bundle im Finder (Nutzeraktion, verändert nichts).
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
