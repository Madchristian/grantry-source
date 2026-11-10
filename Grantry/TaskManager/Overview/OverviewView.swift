import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Übersicht“, Gestaltung „Lagebild“ (docs/design/instrumententafel.md §3.13): oben die Lagezeile mit dem Urteil
/// über den Zustand (`SystemVerdict`), darunter vier Bögen (CPU, Arbeitsspeicher, Leistung, GPU), links die Verläufe
/// als Spuren mit gemeinsamer Zeitachse, rechts was auffällt und die größten Verbraucher. Zeigt nur, was der
/// Task-Manager ohnehin misst; liest nur fertige Stände.
struct OverviewView: View {
    let frame: TaskManagerFrame
    let history: ChartHistory
    let configured: Set<TaskManagerSource>
    let processes: [ProcessMeasurement]
    let interval: String
    let uptime: TimeInterval
    /// Laufende Befunde (`TaskManagerModel.findings`) für Lagezeile und „Auffällig“.
    let findings: [SystemFinding]
    /// Sensoren des Helpers (TM-9.4); ohne Helper fehlen Bogen und Reihe „Leistung“.
    let sensors: SensorReading?
    let sensorHistory: ChartHistory?

    @Environment(\.self) private var environment

    init(frame: TaskManagerFrame, measuredAt: Date, configured: Set<TaskManagerSource>, processes: [ProcessMeasurement],
         interval: String, uptime: TimeInterval = SystemUptime.sinceBoot(), findings: [SystemFinding] = [],
         sensors: SensorReading? = nil, sensorHistory: SampleHistory? = nil, sensorsMeasuredAt: Date = .now) {
        self.frame = frame
        history = ChartHistory(history: frame.history, measuredAt: measuredAt)
        self.configured = configured
        self.processes = processes
        self.interval = interval
        self.uptime = uptime
        self.findings = findings
        self.sensors = sensors
        self.sensorHistory = sensorHistory.map { ChartHistory(history: $0, measuredAt: sensorsMeasuredAt) }
    }

    /// Stand mit den Prozessen samt CPU und Speicher fremder Prozesse.
    private var snapshot: TaskManagerSnapshot {
        var current = frame.snapshot
        current.processes = processes
        return current
    }

    private func color(_ hue: InstrumentHue) -> Color { environment.instrumentColor(hue) }

    /// Leistung in Watt mit derselben Skala wie im Tab „Leistung“.
    private var power: (series: ChartSeries, scale: ChartScale)? {
        guard sensors?.combinedMilliwatts != nil, let sensorHistory else { return nil }
        return (sensorHistory.series(.power, in: .oneMinute), .automatic(minimum: 5))
    }

    var body: some View {
        let snapshot = snapshot
        let verdict = SystemVerdictPresentation.verdict(snapshot: snapshot, findings: findings, interval: interval,
                                                        uptime: uptime)
        let tiles = PerformancePresentation.tiles(for: snapshot, configured: configured)
        VStack(spacing: InstrumentSpacing.panel) {
            VerdictBar(verdict: verdict.title, reason: verdict.reason, finding: verdict.hasFinding,
                       items: verdict.statusItems, facts: facts(verdict))
            gauges(snapshot, tiles: tiles)
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                lanes(snapshot, tiles: tiles)
                OverviewFindings(verdict: verdict, snapshot: snapshot)
                    .frame(width: InstrumentSize.columnWide)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(InstrumentSpacing.page)
        .renderProbe("OverviewView")
    }

    private func facts(_ verdict: SystemVerdict) -> String {
        sensors == nil ? verdict.facts : "\(verdict.facts) · \(String(localized: "Sensoren über den Helper"))"
    }

    // MARK: Bögen

    private func gauges(_ snapshot: TaskManagerSnapshot, tiles: [PerformanceTile]) -> some View {
        let memory = tiles.first { $0.metric == .memory }
        let gpu = tiles.first { $0.metric == .gpu }
        return HStack(spacing: InstrumentSpacing.panel) {
            gauge(String(localized: "CPU"), detail: cores(snapshot), fraction: snapshot.cpu?.total,
                  value: PerformancePresentation.percent(snapshot.cpu?.total), hue: .cpu)
            gauge(String(localized: "Arbeitsspeicher"), detail: memory?.value ?? PerformancePresentation.missing,
                  fraction: snapshot.memory.flatMap(PerformancePresentation.usedShare),
                  value: PerformancePresentation.percent(snapshot.memory.flatMap(PerformancePresentation.usedShare)),
                  hue: .memory)
            if let power, let milliwatts = sensors?.combinedMilliwatts {
                let upper = power.scale.upperBound(for: power.series.values)
                gauge(String(localized: "Leistung"), detail: String(localized: "SoC, über den Helper"),
                      fraction: upper > 0 ? milliwatts / 1000 / upper : nil,
                      value: PerformancePresentation.watts(milliwatts), hue: .power)
            }
            if let gpu, let utilization = snapshot.gpu?.utilization {
                gauge(String(localized: "GPU"), detail: gpu.detail, fraction: utilization, value: gpu.value, hue: .gpu)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func gauge(_ title: String, detail: String, fraction: Double?, value: String,
                       hue: InstrumentHue) -> some View {
        VStack(spacing: InstrumentSpacing.stack) {
            ArcGauge(fraction: fraction, color: color(hue), textColor: environment.instrumentTextColor(hue), value: value,
                     caption: title)
                .frame(height: InstrumentSize.arcGauge)
            Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .instrumentPanel(padding: InstrumentSpacing.cell)
    }

    private func cores(_ snapshot: TaskManagerSnapshot) -> String {
        PerformancePresentation.stats(for: .cpu, in: snapshot, uptime: uptime)
            .first { $0.title == "Kerne" }?.value ?? PerformancePresentation.missing
    }

    // MARK: Verlauf

    private func lanes(_ snapshot: TaskManagerSnapshot, tiles: [PerformanceTile]) -> some View {
        let interface = PerformancePresentation.primaryInterfaceTile(in: tiles, for: snapshot)
        let drive = tiles.first { if case .drive = $0.metric { true } else { false } }
        let memory = tiles.first { $0.metric == .memory }
        let physical = max(Double(snapshot.memory?.physicalBytes ?? 0), 1)
        return VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            PeilHead(String(localized: "Verlauf"), detail: String(localized: "letzte 60 Sekunden, gemeinsame Zeitachse"))
            VerlaufLane(title: String(localized: "CPU"), value: PerformancePresentation.percent(snapshot.cpu?.total),
                        hue: .cpu) {
                LiveGraph(series: history.series(.cpuTotal, in: .oneMinute), overlays: cpuOverlays(snapshot),
                          color: color(.cpu), isInteractive: false)
            }
            VerlaufLane(title: String(localized: "Arbeitsspeicher"), value: memory?.value ?? PerformancePresentation.missing,
                        hue: .memory) {
                LiveGraph(series: history.series(.memoryUsed, in: .oneMinute), scale: .fixed(0...physical),
                          color: color(.memory), isInteractive: false)
            }
            if let interface, case .interface(let name) = interface.metric {
                VerlaufLane(title: interface.title, value: interface.value, hue: .received,
                            spokenTitle: interface.spokenTitle, identifier: "overviewInterface") {
                    MirrorGraph(upper: history.series(.received(name), in: .oneMinute),
                                lower: history.series(.sent(name), in: .oneMinute),
                                colors: (color(.received), color(.sent)))
                }
            }
            if let drive, case .drive(let id) = drive.metric {
                VerlaufLane(title: drive.title, value: drive.value, hue: .diskRead) {
                    MirrorGraph(upper: history.series(.diskRead(id), in: .oneMinute),
                                lower: history.series(.diskWrite(id), in: .oneMinute),
                                colors: (color(.diskRead), color(.diskWrite)))
                }
            }
            HStack(spacing: InstrumentSpacing.page) {
                LegendItem(title: String(localized: "Auslastung"), hue: .cpu)
                if !efficiencyCores(snapshot).isEmpty {
                    LegendItem(title: String(localized: "Effizienzkerne"), hue: .efficiencyCores)
                }
                if power != nil { LegendItem(title: String(localized: "Leistung"), hue: .power) }
                Spacer(minLength: InstrumentSpacing.group)
                TimeAxisLabels(window: 60).frame(maxWidth: InstrumentSize.columnWide)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .instrumentPanel()
    }

    private func cpuOverlays(_ snapshot: TaskManagerSnapshot) -> [LiveGraph.Overlay] {
        var overlays: [LiveGraph.Overlay] = []
        let efficiency = efficiencyCores(snapshot)
        if !efficiency.isEmpty {
            overlays.append(.init(series: history.averageSeries(efficiency.map(MetricKey.cpuCore), in: .oneMinute),
                                  scale: .fixed(0...1), color: color(.efficiencyCores)))
        }
        if let power {
            overlays.append(.init(series: power.series, scale: power.scale, color: color(.power)))
        }
        return overlays
    }

    private func efficiencyCores(_ snapshot: TaskManagerSnapshot) -> [Int] {
        (snapshot.cpu?.cores ?? []).indices.filter { snapshot.cpu?.cores[$0].kind == .efficiency }
    }
}

/// Was auffällt (Prozesse mit Dauerlast, mit Grund) und darunter die größten Verbraucher – so viele, wie in die Höhe
/// passen (Bewertung 2026.11.7, Mangel 11: unten blieb ein Viertel leer).
private struct OverviewFindings: View {
    let verdict: SystemVerdict
    let snapshot: TaskManagerSnapshot

    @Environment(\.self) private var environment

    /// Höhe einer Verbraucher-Zeile samt Abstand.
    private static let rowPitch = InstrumentSize.rowIcon + InstrumentSpacing.inline

    var body: some View {
        let findings = verdict.processFindings
        let shown = Set(findings.map(\.key))
        let consumers = OverviewPresentation.topProcesses(in: snapshot, count: 30).filter { !shown.contains($0.key) }
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            PeilHead(String(localized: "Auffällig"), detail: detail(findings.count), finding: !findings.isEmpty)
            if findings.isEmpty {
                Text(verbatim: SystemVerdictPresentation.quietProcessesText())
                    .font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
            }
            ForEach(findings) { FindingRow(finding: $0, cores: snapshot.cpu?.cores.count ?? 1) }
            Divider()
            Text("Größte Verbraucher").font(InstrumentFont.label.weight(.semibold)).foregroundStyle(.instrumentSecondary)
            GeometryReader { proxy in
                let count = max(Int(proxy.size.height / Self.rowPitch), 0)
                VStack(spacing: InstrumentSpacing.inline) {
                    ForEach(consumers.prefix(count)) { ConsumerRow(process: $0) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .instrumentPanel()
    }

    private func detail(_ count: Int) -> String {
        let total = snapshot.processes.count.formatted()
        return count == 1 ? String(localized: "1 von \(total) Prozessen")
            : String(localized: "\(count) von \(total) Prozessen")
    }
}

private struct FindingRow: View {
    let finding: SystemVerdict.ProcessFinding
    let cores: Int
    @Environment(\.self) private var environment

    var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.cell) {
            FindingDot()
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                HStack {
                    Text(verbatim: finding.name).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(verbatim: PerformancePresentation.percent(finding.cpuLoad)).font(InstrumentFont.numeric)
                }
                Text(verbatim: finding.reason).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                Spur(fraction: min(finding.cpuLoad * Double(max(cores, 1)), 1), color: environment.instrumentColor(.cpu))
                    .frame(height: InstrumentSize.spurList)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ConsumerRow: View {
    /// Spaltenbreiten der Zeile.
    private enum Layout {
        static let spur: CGFloat = 72
        static let cpu: CGFloat = 60
        static let memory: CGFloat = 72
    }

    let process: OverviewProcess
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            Text(verbatim: process.name).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spur(fraction: process.heat, color: environment.instrumentColor(.cpu))
                .frame(width: Layout.spur, height: InstrumentSize.spurList)
                .accessibilityHidden(true)
            Text(verbatim: process.cpu).font(InstrumentFont.numeric)
                .foregroundStyle(environment.instrumentTextColor(.cpu))
                .frame(width: Layout.cpu, alignment: .trailing)
            Text(verbatim: process.memory).font(InstrumentFont.numeric).foregroundStyle(.instrumentSecondary)
                .frame(width: Layout.memory, alignment: .trailing)
        }
        .frame(height: InstrumentSize.rowIcon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(process.name), PID \(process.pid), CPU \(process.cpu), Speicher \(process.memory)"))
        .accessibilityIdentifier("topProcessRow")
    }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
#Preview("Übersicht") {
    OverviewView(frame: TaskManagerPreviewData.frame, measuredAt: .now, configured: TaskManagerPreviewData.configured,
                 processes: ProcessListPreviewData.snapshot
                     .fillingForeignUsage(ProcessListPreviewData.foreignUsage,
                                          currentUID: ProcessListPreviewData.currentUID).processes,
                 interval: "1 s", uptime: TaskManagerPreviewData.uptime)
        .frame(width: 1180, height: 760)
        .instrumentBackground()
}
#endif
