import GrantryCharts
import ManagerKit
import SwiftUI

/// Scan-Abdeckung über den Listen von Berechtigungen, Autostart, Agenten und Apps als Spur (#613, Entwurf LB-2.1, Spec
/// 2026-11-10 § 11.2): Titel nach Zustand, Detail mit gelesenen Quellen und Zeitpunkt, die Spur zeigt denselben Anteil
/// (`AreaCoverage.readSources`) und ist nur bei vollständiger Abdeckung voll. Rechts der nächste Schritt (falls einer
/// hilft) und „Details anzeigen …“ mit Erklärung, Gründen, Hinweisen und „Diagnose kopieren“; das Kontextmenü kopiert
/// die Diagnose direkt. VoiceOver liest den Titel als Beschriftung, Anteil und Detail als Wert (`ProgressSpur`).
struct AreaCoverageSpur: View {
    let coverage: AreaCoverage
    @Environment(\.coverageSteps) private var steps
    @State private var detailReport: CoverageDetailReport?

    var body: some View {
        // Wie die Hinweisleiste: „heute“/„gestern“ bleiben über Mitternacht richtig; die Spur zeichnet nur bei neuem Wert.
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        .sheet(item: $detailReport) { report in
            CoverageDetailsView(report: report.text)
        }
    }

    private func content(now: Date) -> some View {
        ProgressSpur(title: coverage.spurTitle, detail: coverage.spurDetail(now: now),
                     fraction: coverage.readSources.fraction, tone: coverage.tone.statusTone) {
            HStack(spacing: InstrumentSpacing.group) {
                if let steps, let step = coverage.nextStep(missingSetupSteps: steps.missingSetupSteps) {
                    CoverageNextStepButton(step: step, handler: steps)
                        .controlSize(.small)
                }
                if !coverage.isComplete || !coverage.notes(now: now).isEmpty {
                    Button("Details anzeigen …") { showDetails() }
                        .buttonStyle(.link)
                        .font(InstrumentFont.label)
                }
            }
        }
        .help(Text(verbatim: helpText(now: now)))
        .contextMenu {
            Button("Details anzeigen …") { showDetails() }
            Button("Diagnose kopieren") { CoverageCopyButton.copy(coverage.diagnosticReport(now: .now)) }
        }
    }

    /// Bericht zum Zeitpunkt des Öffnens; im Blatt bleibt er eingefroren.
    private func showDetails() {
        detailReport = CoverageDetailReport(text: coverage.diagnosticReport(now: .now))
    }

    /// Tooltip: bei Lücken Erklärung und Gründe, sonst die Zustandszeile.
    private func helpText(now: Date) -> String {
        coverage.isComplete
            ? coverage.statusLine(now: now)
            : ([coverage.explanation] + coverage.reasons(now: now)).joined(separator: "\n")
    }
}

/// Abdeckung und Befund-Hinweis eines Bereichs im Slot von `InventoryBoard`; `leading` steht links neben der Spur (etwa
/// der Umschalter der Berechtigungen). Ohne Snapshot (vor dem ersten Scan) eine leere Spur „Abdeckung unbekannt“.
struct InventoryCoverageControls<Leading: View>: View {
    let coverage: AreaCoverage?
    let flagged: FlaggedBreakdown?
    let area: FlaggedArea
    let filter: FindingFilter
    @ViewBuilder var leading: Leading

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            HStack(alignment: .center, spacing: InstrumentSpacing.panel) {
                leading
                if let coverage {
                    AreaCoverageSpur(coverage: coverage)
                } else {
                    ProgressSpur(title: AreaCoverage.spurTitleBeforeScan, detail: AreaCoverage.spurDetailBeforeScan,
                                 fraction: 0, tone: .neutral)
                }
            }
            FlaggedNoticeBar(breakdown: flagged, area: area, filter: filter)
        }
    }
}

extension InventoryCoverageControls where Leading == EmptyView {
    init(coverage: AreaCoverage?, flagged: FlaggedBreakdown?, area: FlaggedArea, filter: FindingFilter) {
        self.init(coverage: coverage, flagged: flagged, area: area, filter: filter) { EmptyView() }
    }
}

// MARK: - Vorschauen

#Preview("Abdeckung als Spur") {
    let now = Date.now
    var snapshot = Snapshot(takenAt: now, grants: [], autostartItems: [],
                            sourceErrors: [SourceError(source: .btm, message: "Helper nicht erreichbar")],
                            baselineSources: [.tccSystem, .launchd, .btm, .agents, .apps])
    snapshot.sourceLimitations = [SourceLimitation(source: .agents, message: "Netzlaufwerk nicht gelesen")]
    snapshot.lastDeliveryBySource = [.tccSystem: now - 300, .launchd: now - 300, .btm: now - 86_400, .apps: now - 300]
    let overview = CoverageOverview(snapshot: snapshot, activeSources: [.tccSystem, .launchd, .btm, .agents, .apps])
    return VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
        ForEach([InventoryArea.permissions, .autostart, .agents, .apps], id: \.self) { area in
            if let coverage = overview[area] { AreaCoverageSpur(coverage: coverage) }
        }
    }
    .environment(\.coverageSteps, CoverageStepHandler(missingSetupSteps: [.helper]))
    .padding()
    .frame(width: 520)
}
