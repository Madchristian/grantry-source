import GrantryCharts
import ManagerKit
import SwiftUI

// Bausteine der Ansichten im Bereich Netzwerk, Gestaltung „Lagebild“ (docs/design/instrumententafel.md): Verbindungen,
// Dienste und Aktivität teilen sich Verkehrsspiegel, Detailfelder, Hinweise und die Zuordnung zu Zustandstönen.

/// Datenverkehr als Spiegel (§3.4): oben empfangen, unten gesendet, darüber die aktuellen Raten in den Farben der
/// Messgrößen und die Legende. Zeichnet nur, wenn ein neuer Messpunkt kommt.
struct TrafficMirror: View {
    let rate: TrafficRate
    let history: [TrafficRate]
    var height = InstrumentSize.cardGraph
    var accessibilityTitle = String(localized: "Datenverkehr des Systems")

    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            HStack(spacing: InstrumentSpacing.panel) {
                TrafficRateLabel(value: rate.download, direction: .download)
                    .foregroundStyle(environment.instrumentTextColor(.received))
                TrafficRateLabel(value: rate.upload, direction: .upload)
                    .foregroundStyle(environment.instrumentTextColor(.sent))
                Spacer(minLength: InstrumentSpacing.group)
                LegendItem(title: String(localized: "Empfangen"), hue: .received)
                LegendItem(title: String(localized: "Gesendet"), hue: .sent)
            }
            .font(InstrumentFont.label.weight(.medium))
            MirrorGraph(upper: Self.series(history.map(\.download)), lower: Self.series(history.map(\.upload)),
                        window: Double(TrafficTracker.historyLength), minimum: 100_000,
                        colors: (environment.instrumentColor(.received), environment.instrumentColor(.sent)))
                .frame(height: height)
                .accessibilityLabel(Text(verbatim: accessibilityTitle))
        }
    }

    /// Verlauf der Raten, neuester Wert rechts; der Abstand zählt nur die Reihenfolge.
    private static func series(_ values: [Double]) -> ChartSeries {
        ChartSeries(values: values, spacing: 1, latest: Date(timeIntervalSinceReferenceDate: 0))
    }
}

/// Feld im Detail: Titel klein und sekundär, darunter der Inhalt.
struct DetailEntry<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
            Text(verbatim: title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Pfad und Signatur eines Programms im Detail eines Sockets oder Dienstes; bei einem Interpreter auf Wunsch der Hinweis,
/// dass die Signatur nichts über das Skript sagt.
struct ProgramDetailEntries: View {
    let program: NetworkProgram
    var notesInterpreter = false

    var body: some View {
        DetailEntry(title: String(localized: "Pfad")) {
            PathText(path: program.executablePath).font(InstrumentFont.body)
        }
        DetailEntry(title: String(localized: "Signatur")) {
            SigningLabel(signing: program.signing).font(InstrumentFont.body)
        }
        if notesInterpreter && program.isInterpreter {
            NetworkNote(text: String(localized: "Interpreter – die Signatur sagt nichts über das ausgeführte Skript."))
        }
    }
}

/// Hinweis im Inhalt (§3.12): `info.circle` und Text klein in Sekundärfarbe; ein Befund mit Befund-Punkt, ein Fehler mit
/// Symbol in `critical`, beide mit Text in `font.body`.
struct NetworkNote: View {
    enum Kind {
        case info, locked, finding, critical
    }

    let text: String
    var kind = Kind.info

    @Environment(\.self) private var environment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.item) {
            switch kind {
            case .info, .locked:
                Image(systemName: kind == .info ? "info.circle" : "lock").foregroundStyle(.instrumentSecondary)
                    .accessibilityHidden(true)
            case .finding:
                FindingDot(size: InstrumentSize.findingDotSmall)
            case .critical:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(environment.statusColor(.critical))
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .foregroundStyle(kind == .info || kind == .locked ? AnyShapeStyle(.instrumentSecondary)
                    : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(kind == .info || kind == .locked ? InstrumentFont.label : InstrumentFont.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Badges eines Eintrags als kleine Zustandschips (§3.8): „prüfen“ im Ton des Schweregrads, „neu“ und „aufräumen“
/// neutral. VoiceOver liest den Schweregrad mit.
struct RecordBadgeChips: View {
    let badges: [RecordBadge]

    var body: some View {
        HStack(spacing: InstrumentSpacing.inline) {
            ForEach(badges, id: \.self) { badge in
                StatusChip(badge.title, tone: badge.tone.statusTone, isSmall: true)
                    .accessibilityLabel(Text(verbatim: badge.accessibilityLabel))
            }
        }
    }
}

extension NetworkListener {
    /// Erreichbarkeit als Zustand (§2.5): aus dem Netz erreichbare Dienste auffällig, vermutliche Clients neutral, nur
    /// lokal in Ordnung.
    var reachItem: StatusItem {
        if !reachability.isExposed {
            return StatusItem(String(localized: "Nur dieser Mac"), tone: .positive)
        }
        return StatusItem(String(localized: "Aus dem Netz"), tone: isExposedService ? .finding : .neutral)
    }
}

extension RiskFinding.Severity {
    /// Art des Hinweises im Inhalt: hoch als Fehler, sonst als Befund.
    var noteKind: NetworkNote.Kind { self == .high ? .critical : .finding }
}
