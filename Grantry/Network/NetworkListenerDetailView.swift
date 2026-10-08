import ManagerKit
import SwiftUI

/// Ein Lauscher im Detail: Erreichbarkeit und Prüfhinweise, Port, Adressen und Benutzer, Programm samt Signatur und
/// wodurch er vermutlich gestartet wird (#128). „Prozess beenden …“ nach Bestätigung (#128, Teil 2). Darunter live, was
/// das Programm gerade im Netz tut (`NetworkListenerActivitySection`).
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

    private var listener: NetworkListener { row.listener }

    var body: some View {
        Form {
            header
            actionSection
            if !findings.isEmpty {
                Section("Hinweise") { RecordHints(findings: findings) }
            }
            serviceSection
            if let activity {
                NetworkListenerActivitySection(model: activity, executablePath: listener.executablePath)
            }
            programSection
            launchSection
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                NetworkListenerIcon(row: row, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: row.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    StatusLabel(.toned(
                        listener.reachability.isExposed ? .warning : .positive,
                        listener.reachability.isExposed
                            ? String(localized: "Von außen erreichbar")
                            : String(localized: "Nur auf diesem Mac erreichbar")
                    ))
                    RecordBadgesRow(badges: badges)
                }
                Spacer(minLength: 8)
                Button("Im Finder zeigen") { listener.revealInFinder() }
            }
        }
    }

    // MARK: - Aktionen

    /// „Prozess beenden …“, nach einem SIGTERM mit Überlebenden „Sofort beenden (SIGKILL) …“ (zweite Bestätigung).
    /// Ein gesperrter Knopf nennt den Grund (`ListenerTerminationPolicy`) als Tooltip und darunter.
    @ViewBuilder
    private var actionSection: some View {
        if let termination {
            Section("Aktionen") {
                HStack(spacing: 8) {
                    Button("Prozess beenden …", role: .destructive) { termination.prepare(listener) }
                        .disabled(!termination.canStart)
                        .help(termination.disabledReason ?? String(localized: "Beendet den Prozess nach Bestätigung (SIGTERM)."))
                    if termination.offersForce(for: listener) {
                        Button("Sofort beenden (SIGKILL) …", role: .destructive) { termination.flow.offerForce() }
                            .disabled(!termination.actions.canStart)
                    }
                    if let launchedBy, let window {
                        Button("Zum Autostart-Eintrag") { window.show(launchedBy) }
                    }
                    if termination.isBusy(listener) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Aktion läuft")
                    }
                }
                if let reason = termination.disabledReason {
                    HintLabel(text: reason, systemImage: "lock", color: .secondary)
                }
                if let notice = termination.notice(for: listener) {
                    HintLabel(text: notice, systemImage: "info.circle", color: .secondary)
                }
            }
        }
    }

    private var serviceSection: some View {
        Section("Dienst") {
            LabeledContent("Port") { Text(verbatim: listener.portText) }
            LabeledContent("Adressen") {
                Text(verbatim: listener.addresses.isEmpty
                     ? String(localized: "Unbekannt") : listener.addresses.joined(separator: ", "))
                    .textSelection(.enabled)
            }
            LabeledContent("Erreichbarkeit") { Text(verbatim: listener.reachabilityText) }
            LabeledContent("Benutzer") {
                Text(verbatim: ListenerUser(uid: listener.uid, currentUID: getuid()).displayName)
            }
            LabeledContent("Gesehen seit") {
                Text(listener.firstSeenAt, format: .dateTime.day().month().year().hour().minute())
            }
        }
    }

    private var programSection: some View {
        Section("Programm") {
            LabeledContent("Pfad") { PathText(path: listener.executablePath) }
            LabeledContent("Signatur") { SigningLabel(signing: listener.signing) }
            if row.isInterpreter {
                HintLabel(
                    text: String(localized: "Interpreter – die Signatur sagt nichts über das ausgeführte Skript."),
                    systemImage: "info.circle", color: .secondary
                )
            }
        }
    }

    /// Ein Autostart-Eintrag mit gleichem Programm startet den Lauscher sicher; über das eigene Bundle oder die
    /// Eltern-App ist die Zuordnung nur eine Vermutung und wird so beschriftet. Die Eltern-App steht zusätzlich als
    /// „Gestartet aus“ da.
    private var launchSection: some View {
        Section("Gestartet von") {
            if let launchedBy {
                if launchedBy.program == listener.executablePath {
                    LabeledContent("Autostart-Eintrag") { autostartLink(launchedBy) }
                } else {
                    LabeledContent("Vermutlich über Autostart-Eintrag") { autostartLink(launchedBy) }
                }
            }
            if let launchingApp = row.launchingAppPath, let name = row.launchingAppName {
                LabeledContent("Gestartet aus") {
                    BundleAppLabel(path: launchingApp, name: name, signing: .unknown)
                }
            } else if launchedBy == nil, let bundle = row.bundlePath {
                LabeledContent("App") { BundleAppLabel(path: bundle, name: row.title, signing: listener.signing) }
            } else if launchedBy == nil {
                LabeledContent("Herkunft") { Text("Unbekannt") }
            }
        }
    }

    /// Name des Autostart-Eintrags; mit Fenster-Modell ein Link in den Bereich „Autostart“.
    @ViewBuilder
    private func autostartLink(_ item: AutostartItem) -> some View {
        if let window {
            Button {
                window.show(item)
            } label: {
                Text(verbatim: item.label).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("In „Autostart“ zeigen")
        } else {
            Text(verbatim: item.label)
        }
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
    .frame(width: 480, height: 640)
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
    .frame(width: 480, height: 640)
}
#endif
