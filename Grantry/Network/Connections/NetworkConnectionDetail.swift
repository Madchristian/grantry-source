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
        ChartScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
                header
                Divider()
                NetworkConnectionDetailContent(row: row)
                serviceSection
            }
            .padding(InstrumentSpacing.bar)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .instrumentPanel(padding: 0)
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
            DetailGroup(title: String(localized: "Netzwerkdienst")) {
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
            DetailGroup(title: String(localized: "Socket")) {
                DetailField(title: String(localized: "Art"),
                            value: "\(row.protocolText) · \(row.ipVersionText) · \(SocketStateStyle.title(for: row.kind))")
                DetailField(title: String(localized: "Zustand"), value: row.stateText,
                            tone: SocketStateStyle.tone(for: row))
                if let service = row.service {
                    DetailField(title: String(localized: "Dienst"), value: service)
                }
                DetailField(title: String(localized: "Erreichbar"), value: row.exposure.title)
            }
            DetailGroup(title: String(localized: "Adressen")) {
                DetailField(title: String(localized: "Lokal"), value: row.localText)
                DetailField(title: String(localized: "Gegenstelle"), value: row.remoteText)
            }
            if row.kind != .listening {
                DetailGroup(title: String(localized: "Verkehr seit Messbeginn")) {
                    DetailField(title: String(localized: "Empfangen"),
                                value: "\(TrafficFormat.rate(row.rate.download)) · \(TrafficFormat.bytes(row.transferred.received))")
                    DetailField(title: String(localized: "Gesendet"),
                                value: "\(TrafficFormat.rate(row.rate.upload)) · \(TrafficFormat.bytes(row.transferred.sent))")
                }
            }
            if let program = row.program {
                DetailGroup(title: String(localized: "Programm")) {
                    ProgramDetailEntries(program: program)
                }
            }
        }
    }
}

/// Gruppe im Detail: Überschrift, darunter die Felder.
struct DetailGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            Text(verbatim: title)
                .font(InstrumentFont.title)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Feld im Detail: Titel klein, Wert in Festbreitenschrift, auswählbar; mit Ton farbig.
private struct DetailField: View {
    let title: String
    let value: String
    var tone: StatusTone?

    @Environment(\.self) private var environment

    var body: some View {
        DetailEntry(title: title) {
            Text(verbatim: value)
                .font(InstrumentFont.code)
                .foregroundStyle(tone.flatMap { $0 == .neutral ? nil : AnyShapeStyle(environment.statusTextColor($0)) }
                    ?? AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
