import GrantryCharts
import ManagerKit
import SwiftUI

/// Detail eines Sockets unter dem Radar: Programm mit PID und Benutzer, Socket (Art, Zustand, Dienst, Erreichbarkeit),
/// Adressen, Verkehr seit Messbeginn und Programm. Gehört der Socket zu einem Netzwerkdienst des letzten Scans,
/// stehen „Prozess beenden …“ (mit Bestätigung) und der Sprung zum Dienst darunter.
struct NetworkConnectionDetail: View {
    let row: NetworkSocketRow
    /// Netzwerkdienst des letzten Scans zu diesem lauschenden oder gebundenen Socket.
    let listener: NetworkListener?
    /// „Prozess beenden …“; `nil` in Previews und ohne Dienst.
    let termination: ListenerTerminationControls?
    let showListener: ((NetworkListener) -> Void)?

    var body: some View {
        DetailPanel {
            header
            NetworkConnectionDetailContent(row: row)
            serviceSection
        }
    }

    private var header: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            ProgramIcon(program: row.program, title: row.title, size: InstrumentSize.shield)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: row.title)
                    .font(InstrumentFont.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(verbatim: NetworkConnectionTexts.owner(of: row))
                    .font(InstrumentFont.numeric)
                    .foregroundStyle(.instrumentSecondary)
            }
            Spacer(minLength: InstrumentSpacing.group)
            StatusChip(row.reach.title, tone: row.reach.tone.statusTone, isSmall: true)
        }
    }

    @ViewBuilder
    private var serviceSection: some View {
        if let listener {
            DetailGroup(String(localized: "Netzwerkdienst")) {
                if let termination {
                    ListenerTerminationActions(listener: listener, termination: termination) {
                        if let showListener {
                            Button("Zum Netzwerkdienst") { showListener(listener) }
                        }
                    }
                } else if let showListener {
                    Button("Zum Netzwerkdienst") { showListener(listener) }
                }
            }
        }
    }
}

/// Felder des Details ohne Bildlauf und Aktionen (auch für Bilder).
struct NetworkConnectionDetailContent: View {
    let row: NetworkSocketRow

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
            DetailGroup(String(localized: "Socket")) {
                DetailEntry(String(localized: "Art"),
                            value: "\(row.protocolText) · \(row.ipVersionText) · \(SocketStateStyle.title(for: row.kind))")
                DetailEntry(String(localized: "Zustand"), value: row.stateText,
                            tone: SocketStateStyle.tone(for: row), isCode: true)
                if let service = row.service {
                    DetailEntry(String(localized: "Dienst"), value: service, isCode: true)
                }
                DetailEntry(String(localized: "Erreichbar"), value: row.exposure.title)
            }
            DetailGroup(String(localized: "Adressen")) {
                DetailEntry(String(localized: "Lokal"), value: row.localText, isCode: true)
                DetailEntry(String(localized: "Gegenstelle"), value: row.remoteText, isCode: true)
            }
            if row.kind != .listening {
                DetailGroup(String(localized: "Verkehr seit Messbeginn")) {
                    DetailEntry(String(localized: "Empfangen"),
                                value: "\(TrafficFormat.rate(row.rate.download)) · \(TrafficFormat.bytes(row.transferred.received))")
                    DetailEntry(String(localized: "Gesendet"),
                                value: "\(TrafficFormat.rate(row.rate.upload)) · \(TrafficFormat.bytes(row.transferred.sent))")
                }
            }
            if let program = row.program {
                DetailGroup(String(localized: "Programm")) {
                    ProgramDetailEntries(program: program)
                }
            }
        }
    }
}
