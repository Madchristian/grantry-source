import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Chip“ (Apple Silicon): Chipdaten aus `ChipProfile` (sysctl, Gerätebaum – einmal abseits des Main Actors
/// gelesen), Kernlast und GPU aus dem Messtakt, Takt, Aktivität und Watt aus den Sensoren des Helpers; „Takt und
/// Thermik“ aus der Taktverteilung des `SensorModel`, dem Verlauf von `ThermalStateSource` und dem Befund
/// „Drosselung“ (TM-14.3). Ohne Helper bleibt alles andere sichtbar. Liest nur fertige Stände der Models, misst nichts
/// selbst.
struct ChipView: View {
    let frame: TaskManagerFrame
    let history: ChartHistory
    let sensors: SensorReading?
    let sensorHistory: ChartHistory?
    let clockHistory: ClockDistributionHistory
    let thermal: ThermalStateHistory
    let findings: [SystemFinding]
    let thermalNow: Date

    @State private var profile: ChipProfile?

    private static let helperNote = String(
        localized: "Leistung, Takt und Cluster-Aktivität misst der Helper (powermetrics) – ohne ihn bleiben sie leer."
    )

    /// `profile` nur für den Render-Wächter (#372): Ohne ihn liest die Ansicht das Profil nebenläufig nach, und die
    /// Antwort käme zu einem beliebigen Bild an.
    init(frame: TaskManagerFrame, measuredAt: Date, sensors: SensorReading?, sensorHistory: SampleHistory?,
         sensorsMeasuredAt: Date, profile: ChipProfile? = nil,
         clockHistory: ClockDistributionHistory = ClockDistributionHistory(),
         thermal: ThermalStateHistory = ThermalStateHistory(span: TimeInterval(SampleHistory.span.components.seconds)),
         findings: [SystemFinding] = []) {
        self.frame = frame
        history = ChartHistory(history: frame.history, measuredAt: measuredAt)
        self.sensors = sensors
        self.sensorHistory = sensorHistory.map { ChartHistory(history: $0, measuredAt: sensorsMeasuredAt) }
        self.clockHistory = clockHistory
        self.thermal = thermal
        self.findings = findings
        thermalNow = measuredAt
        _profile = State(initialValue: profile)
    }

    var body: some View {
        Group {
            if let profile, profile.isAppleSilicon {
                dashboard(ChipPresentation.page(profile: profile, snapshot: frame.snapshot, sensors: sensors,
                                                thermalState: ProcessInfo.processInfo.thermalState),
                          profile: profile)
            } else if profile != nil {
                ContentUnavailableView("Keine Chipdaten", systemImage: "cpu",
                                       description: Text("Dieser Mac meldet keine Leistungsstufen eines Apple-Chips."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .instrumentPanel()
                    .padding(InstrumentSpacing.page)
            } else {
                Color.clear
            }
        }
        .task {
            guard profile == nil else { return }
            profile = await Task.detached(priority: .utility) { ChipProfile.current }.value
        }
        .renderProbe("ChipView")
    }

    private func dashboard(_ page: ChipPage, profile: ChipProfile) -> some View {
        let readouts = page.energy.map(readout)
        let total = page.energy.firstIndex { $0.kind == .total }.map { readouts[$0] }
        return ChipDashboard(
            title: page.title,
            summary: page.summary,
            engines: page.engines,
            total: total,
            energy: ReadoutStrip(readouts: zip(page.energy, readouts).filter { $0.0.kind != .total }.map(\.1),
                                 note: page.showsHelperHint ? Self.helperNote : nil),
            levels: page.levels.map(level),
            gpu: ChipUnit(title: page.gpu.title, detail: page.gpu.detail, value: page.gpu.value,
                          facts: page.gpu.facts.map(fact), series: history.series(.gpu, in: .oneMinute), hue: .gpu,
                          cores: profile.gpuCoreCount),
            neuralEngine: ChipUnit(title: page.neuralEngine.title, detail: page.neuralEngine.detail,
                                   value: page.neuralEngine.value, facts: page.neuralEngine.facts.map(fact),
                                   series: sensors == nil ? nil : sensorHistory?.series(.neuralEnginePower, in: .oneMinute),
                                   placeholder: String(localized: "Nur mit Helper messbar"),
                                   scale: .automatic(minimum: 1), hue: .neuralEngine, format: GraphAxisLabels.watts),
            clock: clockPanel(ChipPresentation.clock(profile: profile, sensors: sensors, distribution: clockHistory,
                                                     thermal: thermal, now: thermalNow, findings: findings))
        )
    }

    /// Taktbänder in der Farbe der Kernart, Thermik in Zustandstönen.
    private func clockPanel(_ clock: ChipPage.Clock) -> ClockThermalPanel {
        ClockThermalPanel(
            head: ClockThermalPanel.Head(title: clock.title, detail: clock.detail, value: clock.value,
                                         fraction: clock.fraction, finding: clock.finding),
            caption: clock.caption,
            bands: clock.bands.map { band in
                ClockBand(id: band.id, title: band.title, value: band.value, detail: band.detail,
                          hue: band.kind.chartKind.hue,
                          steps: band.steps.map { step in
                              ClockBand.Step(id: step.frequencyMHz, frequency: step.frequency, share: step.share,
                                             heat: step.heat)
                          },
                          placeholder: band.placeholder, accessibilityValue: band.accessibilityValue)
            },
            thermal: ThermalBand(
                current: StatusItem(clock.thermalCurrent, tone: clock.thermalState?.tone ?? .neutral),
                detail: clock.thermalDetail,
                segments: clock.thermalSegments.map { segment in
                    ThermalBand.Segment(start: segment.start, end: segment.end, title: segment.title,
                                        tone: segment.state.tone)
                },
                window: clock.window, accessibilityValue: clock.thermalAccessibilityValue),
            thermalTitle: clock.thermalTitle
        )
    }

    private func level(_ level: ChipPage.Level) -> CoreGrid.Cluster {
        let cores = level.clusters.flatMap(\.cores)
        return CoreGrid.Cluster(
            kind: level.kind.chartKind, title: level.title, detail: level.detail, value: level.value,
            series: history.averageSeries(cores.map(MetricKey.cpuCore), in: .oneMinute),
            groups: level.clusters.map { cluster in
                CoreGrid.Group(title: cluster.title, detail: cluster.detail, cores: cluster.cores.map { core in
                    CoreGrid.Core(id: core, series: history.series(.cpuCore(core), in: .oneMinute))
                })
            },
            facts: level.facts.map(fact), weight: Double(level.weight)
        )
    }

    /// Watt relativ zur Skala des Leistungsverlaufs, damit alle Teile am selben Maß stehen; der thermische Zustand als
    /// Zustandston.
    private func readout(_ readout: ChipPage.Readout) -> ReadoutStrip.Readout {
        if case .thermal(let state) = readout.kind {
            return ReadoutStrip.Readout(title: readout.title, state: readout.value, tone: state.tone)
        }
        let upper = sensorHistory?.wattsUpperBound(in: .oneMinute) ?? 0
        let fraction = readout.level ?? readout.milliwatts.flatMap { upper > 0 ? $0 / 1000 / upper : nil }
        return ReadoutStrip.Readout(title: readout.title, value: readout.value, fraction: fraction, hue: readout.kind.hue)
    }

    private func fact(_ fact: ChipPage.Fact) -> PanelFact { PanelFact(fact.title, fact.value) }
}

extension ChipPage.Readout.Kind {
    /// Farbe wie im übrigen Task-Manager.
    var hue: InstrumentHue {
        switch self {
        case .total: .power
        case .cpu: .cpu
        case .gpu: .gpu
        case .neuralEngine: .neuralEngine
        case .thermal: .power
        }
    }
}

extension ProcessInfo.ThermalState {
    /// Zustandston (§2.5): normal in Ordnung, mäßig und ernst auffällig, kritisch kritisch.
    var tone: StatusTone {
        switch self {
        case .nominal: .positive
        case .fair, .serious: .finding
        case .critical: .critical
        @unknown default: .neutral
        }
    }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Chip") {
    ChipView(frame: TaskManagerPreviewData.frame, measuredAt: .now, sensors: nil, sensorHistory: nil,
             sensorsMeasuredAt: .now)
        .frame(width: 1180, height: 900)
        .instrumentBackground()
}
#endif
