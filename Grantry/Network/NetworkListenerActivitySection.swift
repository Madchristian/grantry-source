import AppKit
import ManagerKit
import SwiftUI

/// Abschnitte „Netzwerkaktivität“, „Prozesse“ und „Verbindungen“ im Detail eines Netzwerkdienstes: was das Programm des
/// Dienstes gerade sendet und empfängt, live über dieselbe nettop-Messung wie die Ansicht „Aktivität“
/// (`ListenerActivityPresenter`). Gemessen wird, solange ein Dienst ausgewählt ist (`NetworkView`); Summen zählen
/// seit Beginn der Messung.
struct NetworkListenerActivitySection: View {
    let model: NetworkActivityModel
    let executablePath: String

    var body: some View {
        let activity = model.listenerActivity(forProgramAt: executablePath)
        Section {
            if let notice = model.notice {
                NetworkActivityNoticeBar(notice: notice, retry: model.retry)
            }
            if model.status.failure == nil {
                content(activity)
            }
        } header: {
            Text("Netzwerkaktivität")
        } footer: {
            Text("Live über nettop, alle Prozesse dieses Programms. Summen seit Beginn der Messung.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.status.failure == nil, !activity.isEmpty {
            if activity.processes.count > 1 || activity.processes.contains(where: \.isGone) {
                processSection(activity.processes)
            }
            connectionSection(activity)
        }
    }

    @ViewBuilder
    private func content(_ activity: ListenerActivity) -> some View {
        if model.frame.report.history.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Messe Netzwerkaktivität …").foregroundStyle(.secondary)
            }
        } else if activity.isEmpty {
            Text("nettop meldet für dieses Programm gerade keinen Prozess mit Netzwerkzugriff.")
                .foregroundStyle(.secondary)
        } else {
            summary(activity)
        }
    }

    @ViewBuilder
    private func summary(_ activity: ListenerActivity) -> some View {
        HStack(spacing: 16) {
            TrafficRateLabel(value: activity.rate.download, direction: .download)
            TrafficRateLabel(value: activity.rate.upload, direction: .upload)
            Spacer(minLength: 8)
            TrafficSparkline(history: activity.history, capacity: TrafficTracker.historyLength,
                             help: "Verlauf dieses Programms (bis 2 Minuten): empfangen (farbig) und gesendet (grau)")
                .frame(width: 140, height: 26)
        }
        .font(.callout)
        LabeledContent("Empfangen gesamt") { BytesText(activity.transferred.received) }
        LabeledContent("Gesendet gesamt") { BytesText(activity.transferred.sent) }
        LabeledContent("Offene Verbindungen") { Text(verbatim: connectionSummary(activity)) }
        LabeledContent("Gegenstellen") { Text(verbatim: "\(activity.remoteHostCount)").monospacedDigit() }
        if activity.processes.count == 1, let process = activity.processes.first {
            LabeledContent("Prozess") { Text(verbatim: "\(process.shortName) · PID \(process.pid)") }
        }
    }

    /// „5 (2 eingehend, 3 ausgehend)“; UDP/QUIC ohne Richtung zählen nur zur Gesamtzahl.
    private func connectionSummary(_ activity: ListenerActivity) -> String {
        let total = activity.openConnections.count
        let inbound = activity.openConnectionCount(.inbound)
        let outbound = activity.openConnectionCount(.outbound)
        guard inbound + outbound > 0 else { return "\(total)" }
        return "\(String(total)) (\(String(inbound)) eingehend, \(String(outbound)) ausgehend)"
    }

    private func processSection(_ processes: [ListenerActivity.Process]) -> some View {
        Section("Prozesse") {
            ForEach(processes) { process in
                HStack(spacing: 12) {
                    Text(verbatim: "\(process.shortName) · PID \(process.pid)")
                        .lineLimit(1)
                    if process.isGone {
                        Text("beendet").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    RatePair(rate: process.rate)
                    BytesText(process.transferred.total)
                        .help("Übertragen seit Beginn der Messung")
                }
                .opacity(process.isGone ? 0.45 : 1)
            }
        }
    }

    private func connectionSection(_ activity: ListenerActivity) -> some View {
        Section {
            if activity.connections.isEmpty {
                Text("Keine offenen Verbindungen.").foregroundStyle(.secondary)
            } else {
                ForEach(activity.connections) { connection in
                    ListenerConnectionRow(connection: connection, showsPID: activity.processes.count > 1)
                }
            }
        } header: {
            Text("Verbindungen")
        }
    }
}

/// Eine Verbindung im Dienst-Detail: Richtung, Gegenstelle (Hostname und Adresse), Einordnung, Protokoll, Zustand,
/// lokale Seite, Raten und übertragene Bytes; Kontextmenü zum Kopieren.
private struct ListenerConnectionRow: View {
    let connection: ListenerActivity.Connection
    let showsPID: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(Text(verbatim: connection.direction?.displayName ?? connection.connection.transport.displayName))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: connection.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if connection.isNew {
                        Text("neu")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(PresentationTone.positive.color.opacity(0.2), in: Capsule())
                    }
                    if connection.isGone {
                        Text("geschlossen").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: primaryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(verbatim: secondaryDetail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                RatePair(rate: connection.rate)
                Text(verbatim: "↓ \(TrafficFormat.bytes(connection.transferred.received))  ↑ \(TrafficFormat.bytes(connection.transferred.sent))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Übertragen seit Beginn der Messung")
            }
        }
        .opacity(connection.isGone ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: connection.accessibilityLabel))
        .contextMenu {
            if let target = connection.target {
                Button("Ziel kopieren") { copy(target) }
            }
            if connection.connection.remote.address != nil {
                Button("Adresse kopieren") { copy(connection.remoteEndpoint) }
            }
        }
    }

    private var symbol: String {
        switch connection.direction {
        case .inbound: "arrow.down.left"
        case .outbound: "arrow.up.right"
        case nil: "arrow.left.arrow.right"
        }
    }

    /// „Ausgehend · Internet · 192.0.2.10:443 · TCP · IPv4 · Established“ – die Adresse nur neben einem Hostnamen.
    private var primaryDetail: String {
        [
            connection.direction?.displayName,
            connection.location?.displayName,
            connection.hostName == nil ? connection.connection.remote.port.map { "Port \(String($0))" }
                : connection.remoteEndpoint,
            connection.protocolText,
            connection.state,
        ].compactMap(\.self).joined(separator: " · ")
    }

    /// „Lokal 192.0.2.1:50000 · PID 4242“.
    private var secondaryDetail: String {
        var parts = ["Lokal \(connection.localEndpoint)"]
        if showsPID { parts.append("PID \(connection.pid)") }
        return parts.joined(separator: " · ")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// „↓ 1,2 KB/s  ↑ 300 B/s“; ruhend in Sekundärfarbe.
private struct RatePair: View {
    let rate: TrafficRate

    var body: some View {
        Text(verbatim: "↓ \(TrafficFormat.rate(rate.download))  ↑ \(TrafficFormat.rate(rate.upload))")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(rate.total > 0 ? .primary : .secondary)
            .accessibilityLabel(Text(verbatim:
                "empfängt \(TrafficFormat.rate(rate.download)), sendet \(TrafficFormat.rate(rate.upload))"))
    }
}

private struct BytesText: View {
    let count: UInt64

    init(_ count: UInt64) { self.count = count }

    var body: some View {
        Text(verbatim: TrafficFormat.bytes(count))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview("Dienst-Aktivität") {
    Form {
        NetworkListenerActivitySection(
            model: .preview(frame: NetworkActivityPreviewData.frame, status: .running,
                            hostNames: NetworkActivityPreviewData.hostNames),
            executablePath: NetworkListener.preview.executablePath
        )
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 640)
}
#endif
