import GrantryCharts
import ManagerKit

// Zuordnung der Darstellung „Belegung“ (ManagerKit) zu den Bausteinen des Lagebilds (GrantryCharts): Töne, Symbole und
// Inhalte des `OccupancyBoard`. Eine Stelle, damit App und Mess-Harness dieselbe Ansicht zeigen.

extension OccupancyPresentation.Tone {
    var statusTone: StatusTone {
        switch self {
        case .positive: .positive
        case .info: .info
        case .neutral: .neutral
        case .critical: .critical
        }
    }
}

extension OccupancyPresentation.Chip {
    var statusItem: StatusItem { StatusItem(text, tone: tone.statusTone) }
}

extension OccupancyPresentation.Fact {
    var panelFact: PanelFact { PanelFact(title, value) }
}

extension OccupancyPresentation.Row.Kind {
    var symbol: String {
        switch self {
        case .folder, .more: "folder"
        case .files: "doc"
        case .otherVolume: "externaldrive"
        case .network: "network"
        case .cloud: "icloud"
        }
    }
}

extension OccupancyPresentation {
    var boardContent: OccupancyBoardContent {
        OccupancyBoardContent(
            verdict: verdict, finding: finding, items: items.map(\.statusItem), facts: facts,
            volumes: volumes.map { volume in
                OccupancyVolumeContent(
                    id: volume.id, title: volume.title, detail: volume.detail, value: volume.value, fraction: volume.fraction,
                    parts: volume.parts.map {
                        ShareBand.Part(id: $0.id, title: $0.title, value: $0.value, fraction: $0.fraction, level: $0.level)
                    },
                    free: (String(localized: "frei"), volume.free))
            },
            devices: OccupancyDevicesContent(
                detail: devices.detail,
                devices: devices.devices.map { device in
                    OccupancyDevicesContent.Device(id: device.id, symbol: device.isInternal ? "internaldrive" : "externaldrive",
                                                   title: device.title, detail: device.detail,
                                                   smart: device.smart.statusItem, facts: device.facts.map(\.panelFact))
                },
                note: devices.note),
            ladder: OccupancyLadderContent(
                detail: ladder.detail, value: ladder.value,
                steps: ladder.steps.map { PathSteps.Step(id: $0.depth, title: $0.title) }, notes: ladder.notes,
                offersFullDiskAccess: ladder.offersFullDiskAccess, state: ladder.state.boardState),
            detail: detail.map { detail in
                OccupancyDetailContent(
                    title: detail.title, detail: detail.detail, value: detail.value, path: detail.displayPath,
                    fields: detail.fields.map { ($0.title, $0.value) },
                    hints: detail.hints.map { .init(title: $0.title, status: $0.status.statusItem, text: $0.text) },
                    largestFiles: detail.largestFiles.map(\.panelFact), canShowInFinder: true,
                    cleanupTitle: detail.cleanupTitle)
            },
            bar: OccupancyBarContent(status: bar.status, isScanning: bar.isScanning, scanTitle: bar.scanTitle,
                                     canScan: bar.canScan))
    }
}

extension OccupancyPresentation.LadderState {
    var boardState: OccupancyLadderContent.State {
        switch self {
        case .placeholder(let title, let description, let symbol):
            .placeholder(title: title, description: description, symbol: symbol)
        case .rows(let rows, let selection):
            .rows(rows.map { row in
                LadderRow.Content(id: row.id, symbol: row.kind.symbol, name: row.name, value: row.value,
                                  fraction: row.fraction, chip: row.chip?.statusItem, isDescendable: row.isDescendable,
                                  isMuted: row.isMuted, accessibilityLabel: row.accessibilityLabel)
            }, selection: selection)
        }
    }
}

extension OccupancyScope {
    /// Umfang im Umschalter des Lagebilds.
    var boardScope: OccupancyBoardScope {
        switch self {
        case .home: .home
        case .volume: .volume
        }
    }

    init(_ scope: OccupancyBoardScope) {
        self = switch scope {
        case .home: .home
        case .volume: .volume
        }
    }
}
