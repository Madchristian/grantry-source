import GrantryCharts
import ManagerKit
import SwiftUI

/// Ein Lauscher im Detail-Panel rechts (Gestaltung „Lagebild“, #366): Erreichbarkeit und Prüfhinweise, Port, Adressen
/// und Benutzer, Programm samt Signatur und wodurch er vermutlich gestartet wird (#128). „Prozess beenden …“ nach
/// Bestätigung (#128, Teil 2). Darunter live, was das Programm gerade im Netz tut (`NetworkListenerActivitySection`).
struct NetworkListenerDetailView: View {
    let row: NetworkListenerRow
    let badges: [RecordBadge]
    let findings: [RiskFinding]
    /// Autostart-Eintrag, der den Lauscher vermutlich startet (`NetworkOverview.launchedBy(_:)`).
    let launchedBy: AutostartItem?
    /// „Prozess beenden …“; `nil` in Previews.
    let termination: ListenerTerminationControls?
    /// Live-Messung für die Abschnitte zur Netzwerkaktivität; `nil` blendet sie aus.
    var activity: NetworkActivityModel?
    /// Fehlt in Previews; der Autostart-Eintrag ist dann nicht anklickbar.
    @Environment(MainWindowModel.self) private var window: MainWindowModel?
    @Environment(\.self) private var environment

    private var listener: NetworkListener { row.listener }

    var body: some View {
        DetailPanel {
            header
            actionGroup
            if !findings.isEmpty {
                DetailGroup(String(localized: "Hinweise")) {
                    ForEach(findings) { InstrumentNote($0.message, kind: $0.severity.noteKind) }
                }
            }
            serviceGroup
            if let activity {
                NetworkListenerActivitySection(model: activity, executablePath: listener.executablePath)
            }
            DetailGroup(String(localized: "Programm")) {
                ProgramDetailEntries(program: listener.program, notesInterpreter: true)
            }
            launchGroup
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            HStack(spacing: InstrumentSpacing.panel) {
                NetworkListenerIcon(row: row, size: InstrumentSize.shield)
                VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                    Text(verbatim: row.title)
                        .font(InstrumentFont.value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(verbatim: listener.portText)
                        .font(InstrumentFont.code)
                        .foregroundStyle(.instrumentSecondary)
                }
                Spacer(minLength: InstrumentSpacing.group)
            }
            HStack(spacing: InstrumentSpacing.item) {
                StatusChip(listener.reachItem)
                BadgeChips(badges.map(\.instrumentBadge))
                Spacer(minLength: InstrumentSpacing.group)
                Button("Im Finder zeigen") { listener.revealInFinder() }
            }
        }
    }

    // MARK: - Aktionen

    /// „Prozess beenden …“ samt SIGKILL-Angebot, Hinweisen und Sprung zum Autostart-Eintrag (`ListenerTerminationActions`).
    @ViewBuilder
    private var actionGroup: some View {
        if let termination {
            DetailGroup(String(localized: "Aktionen")) {
                ListenerTerminationActions(listener: listener, termination: termination) {
                    if let launchedBy, let window {
                        Button("Zum Autostart-Eintrag") { window.show(launchedBy) }
                    }
                }
            }
        }
    }

    private var serviceGroup: some View {
        DetailGroup(String(localized: "Dienst")) {
            entry(String(localized: "Port"), listener.portText)
            entry(String(localized: "Adressen"), listener.addresses.isEmpty
                  ? String(localized: "Unbekannt") : listener.addresses.joined(separator: ", "))
            entry(String(localized: "Erreichbarkeit"), listener.reachabilityText)
            entry(String(localized: "Benutzer"), ListenerUser(uid: listener.uid, currentUID: getuid()).displayName)
            DetailEntry(String(localized: "Gesehen seit"),
                        value: listener.firstSeenAt.formatted(.dateTime.day().month().year().hour().minute()))
        }
    }

    private func entry(_ title: String, _ value: String) -> some View {
        DetailEntry(title, value: value, isCode: true)
    }

    /// Ein Autostart-Eintrag mit gleichem Programm startet den Lauscher sicher; über das eigene Bundle oder die
    /// Eltern-App ist die Zuordnung nur eine Vermutung und wird so beschriftet. Die Eltern-App steht zusätzlich als
    /// „Gestartet aus“ da.
    private var launchGroup: some View {
        DetailGroup(String(localized: "Gestartet von")) {
            if let launchedBy {
                DetailEntry(launchedBy.program == listener.executablePath
                            ? String(localized: "Autostart-Eintrag") : String(localized: "Vermutlich über Autostart-Eintrag"),
                            control: { autostartLink(launchedBy) })
            }
            if let launchingApp = row.launchingAppPath, let name = row.launchingAppName {
                DetailEntry(String(localized: "Gestartet aus"), value: name) {
                    BundleAppLabel(path: launchingApp, name: name, signing: .unknown).font(InstrumentFont.body)
                }
            } else if launchedBy == nil, let bundle = row.bundlePath {
                DetailEntry(String(localized: "App"), value: row.title) {
                    BundleAppLabel(path: bundle, name: row.title, signing: listener.signing).font(InstrumentFont.body)
                }
            } else if launchedBy == nil {
                entry(String(localized: "Herkunft"), String(localized: "Unbekannt"))
            }
        }
    }

    /// Name des Autostart-Eintrags; mit Fenster-Modell ein Link in den Bereich „Autostart“ in der Textfarbe von `info`.
    @ViewBuilder
    private func autostartLink(_ item: AutostartItem) -> some View {
        if let window {
            Button {
                window.show(item)
            } label: {
                Text(verbatim: item.label).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(environment.statusTextColor(.info))
            .font(InstrumentFont.body)
            .help("In „Autostart“ zeigen")
        } else {
            Text(verbatim: item.label).font(InstrumentFont.body)
        }
    }
}

/// Leeres Detail, solange kein Dienst gewählt ist (§3.11).
struct NetworkListenerNoSelection: View {
    var body: some View {
        VStack(spacing: InstrumentSpacing.group) {
            Image(systemName: "network").font(.largeTitle).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text("Wähle einen Dienst, um Erreichbarkeit, Aktivität und Programm zu sehen.")
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(InstrumentSpacing.empty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .instrumentPanel(padding: 0)
    }
}

#if DEBUG
#Preview("Lauscher-Detail") {
    NetworkListenerDetailView(
        row: NetworkListenerRow(.preview, severity: .medium), badges: [.review(.medium)],
        findings: [], launchedBy: nil, termination: nil,
        activity: .preview(frame: NetworkActivityPreviewData.frame, status: .running,
                           hostNames: NetworkActivityPreviewData.hostNames)
    )
    .frame(width: 400, height: 900)
    .padding(14)
    .instrumentBackground()
}

/// Abschnitt „Aktionen“ mit gesperrtem Knopf (root-Lauscher ohne Helper); ohne Coordinator, beendet nichts.
#Preview("Lauscher-Detail, Aktionen") {
    let actions = ActionRunner(helperActivity: HelperActivityLock(), coordinator: nil)
    NetworkListenerDetailView(
        row: NetworkListenerRow(.previewRoot, severity: .high), badges: [.review(.high)],
        findings: [], launchedBy: nil,
        termination: ListenerTerminationControls(
            flow: ProcessTerminationFlow(
                resolver: ListenerProcessResolver(provider: nil), actions: actions, ledger: ListenerTerminationLedger(),
                refresh: {}
            ),
            actions: actions, availability: .readOnly(.helperRequired)
        )
    )
    .frame(width: 400, height: 640)
    .padding(14)
    .instrumentBackground()
}
#endif
