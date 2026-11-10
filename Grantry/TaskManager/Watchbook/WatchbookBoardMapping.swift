import GrantryCharts
import ManagerKit

// Zuordnung der Darstellung „Wachbuch“ (ManagerKit) zu den Inhalten der Tafel (GrantryCharts): Farben je Messgröße,
// Töne, Symbole der Quellen und Skalen an einer Stelle (wie `ExtensionBoardMapping`).

/// Was die Tafel zeigt, einmal je gelesener Reihe zugeordnet – nicht bei jeder Bewegung der Zeitmarke.
struct WatchbookScreen {
    let presentation: WatchbookPresentation
    let status: WatchbookStatus
    let state: WatchbookBoardState
    let findingRows: [WatchbookFindingRowContent]

    init(_ presentation: WatchbookPresentation) {
        self.presentation = presentation
        let status = presentation.status
        self.status = WatchbookStatus(verdict: status.title, finding: status.hasFinding,
                                      items: status.items.map { StatusItem($0.text, tone: $0.tone.statusTone) },
                                      facts: status.facts)
        state = switch presentation.state {
        case .off: .off
        case .loading: .loading
        case .empty: .empty
        case .recorded: .recorded(WatchbookBoardMapping.timeline(presentation))
        }
        findingRows = presentation.findingRows.map(WatchbookBoardMapping.findingRow)
    }

    /// Panel „Zu diesem Zeitpunkt“ und Tabelle „Befunde“ (TM-12.6) samt den Zielen der Sprünge nach ihrer Kennung.
    func analysis(at column: Int?, consumers: WatchbookConsumerState,
                  liveness: (ProcessKey) -> ProcessLiveness) -> (content: WatchbookAnalysis,
                                                                 targets: [String: WatchbookJumpTarget]) {
        let moment = column.flatMap { presentation.moment(at: $0, consumers: consumers, liveness: liveness) }
        let jumps = (moment.map { $0.findings + $0.changes } ?? []).compactMap(\.jump)
        return (WatchbookAnalysis(moment: moment.map(WatchbookBoardMapping.moment), findings: findingRows,
                                  findingsEmptyText: presentation.findingsEmptyText),
                Dictionary(jumps.map { ($0.target.id, $0.target) }, uniquingKeysWith: { first, _ in first }))
    }

    func readout(at column: Int?) -> WatchbookReadout? {
        guard case .recorded = state else { return nil }
        let readout = presentation.readout(at: column)
        return WatchbookReadout(time: readout.time, laneValues: readout.laneValues, thermal: readout.thermal)
    }
}

enum WatchbookBoardMapping {
    static func timeline(_ presentation: WatchbookPresentation) -> WatchbookTimelineContent {
        WatchbookTimelineContent(
            lanes: presentation.lanes.map(lane), marks: presentation.marks.map(mark),
            thermal: presentation.thermal.map { $0?.statusTone },
            axis: presentation.axis.map { WatchbookAxisTick(position: $0.position, label: $0.label) },
            markerStep: presentation.markerStep, eventSummary: presentation.eventSummary
        )
    }

    static func lane(_ lane: WatchbookPresentation.Lane) -> WatchbookLaneContent {
        let upper = lane.upper.map(value), lower = lane.lower?.map(value)
        let upperBound = switch lane.scale {
        case .fraction: 1.0
        case .total(let total): total
        case .rate: MirrorGraph.scale.upperBound(for: (upper + (lower ?? [])).map { $0?.maximum })
        }
        let graph: WatchbookLaneContent.Graph = if let lower {
            .mirror(upper: upper, lower: lower, upperBound: upperBound, upperHue: lane.kind.hue,
                    lowerHue: lane.kind.lowerHue)
        } else {
            .line(values: upper, upperBound: upperBound, hue: lane.kind.hue)
        }
        return WatchbookLaneContent(id: "\(lane.kind)", title: lane.title, hue: lane.kind.hue, graph: graph)
    }

    static func mark(_ mark: WatchbookPresentation.Mark) -> WatchbookMarkContent {
        WatchbookMarkContent(id: mark.id.uuidString, style: style(mark.style), start: mark.start, end: mark.end,
                             symbol: mark.source?.symbol, text: mark.text)
    }

    static func findingRow(_ row: WatchbookPresentation.FindingRow) -> WatchbookFindingRowContent {
        WatchbookFindingRowContent(id: row.id.uuidString, isCritical: row.isCritical, start: row.start,
                                   duration: row.duration, kind: row.kind, reason: row.reason, cause: row.cause)
    }

    static func moment(_ moment: WatchbookPresentation.Moment) -> WatchbookMomentContent {
        WatchbookMomentContent(
            time: moment.time, values: moment.values.map { WatchbookMomentValue(title: $0.title, value: $0.value) },
            cpuConsumers: moment.cpuConsumers.map(consumer), memoryConsumers: moment.memoryConsumers.map(consumer),
            consumersNote: moment.consumersNote, findings: moment.findings.map(entry), changes: moment.changes.map(entry)
        )
    }

    private static func consumer(_ consumer: WatchbookPresentation.MomentConsumer) -> WatchbookConsumerContent {
        WatchbookConsumerContent(id: consumer.id, name: consumer.name, badge: consumer.badge, value: consumer.value,
                                 fraction: consumer.fraction)
    }

    private static func entry(_ entry: WatchbookPresentation.MomentEntry) -> WatchbookMomentEntry {
        WatchbookMomentEntry(id: entry.id.uuidString, style: style(entry.style), symbol: entry.source?.symbol,
                             title: entry.title, time: entry.time, detail: entry.detail,
                             jump: entry.jump.map { WatchbookJumpContent(id: $0.target.id, title: $0.title, note: $0.note) })
    }

    private static func style(_ style: WatchbookPresentation.Mark.Style) -> WatchbookMarkContent.Style {
        switch style {
        case .finding: .finding
        case .critical: .critical
        case .change: .change
        case .system: .system
        }
    }

    private static func value(_ statistic: WatchbookStatistic?) -> TimelineValue? {
        statistic.map { TimelineValue(minimum: $0.minimum, maximum: $0.maximum, mean: $0.mean) }
    }
}

extension WatchbookPresentation.Lane.Kind {
    /// Farbe der Spur und ihres Werts; bei Spiegeln die obere Reihe (empfangen, lesen).
    var hue: InstrumentHue {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .network: .received
        case .disk: .diskRead
        }
    }

    /// Untere Reihe der Spiegel (gesendet, schreiben).
    var lowerHue: InstrumentHue {
        switch self {
        case .network: .sent
        case .disk: .diskWrite
        case .cpu, .memory: hue
        }
    }
}

extension WatchbookPresentation.MarkSource {
    /// Symbol der Quelle: Änderungen wie ihr Bereich in der Seitenleiste, Systemereignisse eigens.
    var symbol: String {
        switch self {
        case .change(let source):
            switch source {
            case .autostart: MainSection.autostart.systemImage
            case .networkService: MainSection.network.systemImage
            case .app: MainSection.apps.systemImage
            case .agent: MainSection.agents.systemImage
            case .extensionRecord: MainSection.extensions.systemImage
            }
        case .system(let kind):
            switch kind {
            case .boot: "power"
            case .sleep: "moon.zzz"
            case .wake: "sun.max"
            case .powerAdapterConnected: "powerplug"
            case .powerAdapterDisconnected: "battery.50percent"
            case .lowPowerModeOn, .lowPowerModeOff: "leaf"
            case .thermalState: "thermometer.medium"
            case .memoryPressure: "memorychip"
            }
        }
    }
}
