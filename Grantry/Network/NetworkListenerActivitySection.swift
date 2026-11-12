import AppKit
import GrantryCharts
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
        DetailGroup(String(localized: "Netzwerkaktivität")) {
            if let notice = model.notice {
                NetworkActivityNoticeBar(notice: notice, retry: model.retry)
            }
            if model.status.failure == nil {
                content(activity)
            }
            InstrumentNote(String(localized: "Live über nettop, alle Prozesse dieses Programms. Summen seit Beginn der Messung."))
        }
        if model.status.failure == nil, !activity.isEmpty {
            if activity.processes.count > 1 || activity.processes.contains(where: \.isGone) {
                processGroup(activity.processes)
            }
            connectionGroup(activity)
        }
    }

    @ViewBuilder
    private func content(_ activity: ListenerActivity) -> some View {
        if model.frame.report.history.isEmpty {
            HStack(spacing: InstrumentSpacing.group) {
                ProgressView().controlSize(.small)
                Text("Messe Netzwerkaktivität …").font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
            }
        } else if activity.isEmpty {
            Text("nettop meldet für dieses Programm gerade keinen Prozess mit Netzwerkzugriff.")
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
        } else {
            summary(activity)
        }
    }

    @ViewBuilder
    private func summary(_ activity: ListenerActivity) -> some View {
        TrafficMirror(rate: activity.rate, history: activity.history,
                      accessibilityTitle: String(localized: "Verlauf dieses Programms"))
        MeasureFieldRow(fields: [
            (String(localized: "Empfangen gesamt"), TrafficFormat.bytes(activity.transferred.received)),
            (String(localized: "Gesendet gesamt"), TrafficFormat.bytes(activity.transferred.sent)),
            (String(localized: "Offene Verbindungen"), connectionSummary(activity)),
            (String(localized: "Gegenstellen"), "\(activity.remoteHostCount)"),
        ])
        if activity.processes.count == 1, let process = activity.processes.first {
            DetailEntry(String(localized: "Prozess"), value: "\(process.shortName) · PID \(process.pid)", isCode: true)
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

    private func processGroup(_ processes: [ListenerActivity.Process]) -> some View {
        DetailGroup(String(localized: "Prozesse")) {
            ForEach(processes) { process in
                HStack(spacing: InstrumentSpacing.group) {
                    Text(verbatim: "\(process.shortName) · PID \(process.pid)")
                        .font(InstrumentFont.body)
                        .lineLimit(1)
                        .foregroundStyle(process.isGone ? .instrumentSecondary : .primary)
                    if process.isGone {
                        StatusChip(String(localized: "beendet"), tone: .neutral, isSmall: true)
                    }
                    Spacer(minLength: InstrumentSpacing.group)
                    RatePair(rate: process.rate)
                    BytesText(process.transferred.total)
                        .help("Übertragen seit Beginn der Messung")
                }
            }
        }
    }

    private func connectionGroup(_ activity: ListenerActivity) -> some View {
        DetailGroup(String(localized: "Verbindungen")) {
            if activity.connections.isEmpty {
                Text("Keine offenen Verbindungen.").font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
            } else {
                ForEach(activity.connections) { connection in
                    ListenerConnectionRow(connection: connection, showsPID: activity.processes.count > 1)
                }
            }
        }
    }
}

/// Eine Verbindung im Dienst-Detail: Richtung, Gegenstelle (Hostname und Adresse), Einordnung, Protokoll, Zustand,
/// lokale Seite, Raten und übertragene Bytes; Kontextmenü zum Kopieren.
private struct ListenerConnectionRow: View {
    let connection: ListenerActivity.Connection
    let showsPID: Bool

    var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.group) {
            Image(systemName: symbol)
                .foregroundStyle(.instrumentSecondary)
                .frame(width: InstrumentSize.disclosure)
                .help(Text(verbatim: connection.direction?.displayName ?? connection.connection.transport.displayName))
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                HStack(spacing: InstrumentSpacing.item) {
                    Text(verbatim: connection.title)
                        .font(InstrumentFont.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(connection.isGone ? .instrumentSecondary : .primary)
                    if connection.isNew {
                        StatusChip(String(localized: "neu"), tone: .info, isSmall: true)
                    }
                    if connection.isGone {
                        StatusChip(String(localized: "geschlossen"), tone: .neutral, isSmall: true)
                    }
                }
                Group {
                    Text(verbatim: primaryDetail)
                    Text(verbatim: secondaryDetail)
                }
                .font(InstrumentFont.label)
                .foregroundStyle(.instrumentSecondary)
                .textSelection(.enabled)
                HStack(spacing: InstrumentSpacing.group) {
                    RatePair(rate: connection.rate)
                    Text(verbatim: "↓ \(TrafficFormat.bytes(connection.transferred.received))  ↑ \(TrafficFormat.bytes(connection.transferred.sent))")
                        .font(InstrumentFont.label.monospacedDigit())
                        .foregroundStyle(.instrumentSecondary)
                        .help("Übertragen seit Beginn der Messung")
                }
            }
        }
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
            .font(InstrumentFont.numeric)
            .foregroundStyle(rate.total > 0 ? Color.primary : .instrumentSecondary)
            .accessibilityLabel(Text(verbatim:
                "empfängt \(TrafficFormat.rate(rate.download)), sendet \(TrafficFormat.rate(rate.upload))"))
    }
}

private struct BytesText: View {
    let count: UInt64

    init(_ count: UInt64) { self.count = count }

    var body: some View {
        Text(verbatim: TrafficFormat.bytes(count))
            .font(InstrumentFont.numeric)
            .foregroundStyle(.instrumentSecondary)
    }
}

#if DEBUG
#Preview("Dienst-Aktivität") {
    VStack(alignment: .leading, spacing: 16) {
        NetworkListenerActivitySection(
            model: .preview(frame: NetworkActivityPreviewData.frame, status: .running,
                            hostNames: NetworkActivityPreviewData.hostNames),
            executablePath: NetworkListener.preview.executablePath
        )
    }
    .padding(16)
    .frame(width: 400, height: 640)
    .instrumentPanel()
}
#endif
