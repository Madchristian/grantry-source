import GrantryCharts
import ManagerKit
import SwiftUI

// Bausteine der Ansichten im Bereich Netzwerk, Gestaltung „Lagebild“ (docs/design/instrumententafel.md): Verbindungen,
// Dienste und Aktivität teilen sich Verkehrsspiegel, Programmangaben und die Zuordnung zu Zustandstönen. Detail-Panel,
// Schlüssel-Wert-Zeilen, Hinweise und Badges kommen zentral aus GrantryCharts (`DetailPanel`, `DetailEntry`,
// `InstrumentNote`, `BadgeChips`; LB-1.2, #536).

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

/// Pfad und Signatur eines Programms im Detail eines Sockets oder Dienstes; bei einem Interpreter auf Wunsch der Hinweis,
/// dass die Signatur nichts über das Skript sagt.
struct ProgramDetailEntries: View {
    let program: NetworkProgram
    var notesInterpreter = false

    var body: some View {
        DetailEntry(String(localized: "Pfad"), value: program.executablePath) {
            PathText(path: program.executablePath).font(InstrumentFont.body)
        }
        DetailEntry(String(localized: "Signatur"), value: program.signing.fullText) {
            SigningLabel(signing: program.signing).font(InstrumentFont.body)
        }
        if notesInterpreter && program.isInterpreter {
            InstrumentNote(String(localized: "Interpreter – die Signatur sagt nichts über das ausgeführte Skript."))
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
    var noteKind: InstrumentNote.Kind { self == .high ? .critical : .finding }
}
