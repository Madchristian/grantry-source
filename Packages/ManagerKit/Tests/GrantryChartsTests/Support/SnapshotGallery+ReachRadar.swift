import SwiftUI
@testable import GrantryCharts

/// Karte „Erreichbarkeit“ (Netzwerk › Verbindungen) mit vielen lauschenden Programmen: in der Spalte und auf die ganze
/// Seite vergrößert. Stand wie im Auftrag zum Vergrößern: sechs Programme nur auf diesem Mac, zwei im lokalen Netz und
/// 17 aus dem Netz erreichbar.
@MainActor
extension SnapshotGallery {
    enum ReachRadarScene: String, CaseIterable, Sendable {
        case card = "karte"
        case page = "seite"

        var isExpanded: Bool { self == .page }

        var size: CGSize {
            switch self {
            case .card: CGSize(width: InstrumentSize.columnRadar, height: 372)
            case .page: CGSize(width: 1100, height: 760)
            }
        }
    }

    static let reachEchoes: [ReachRadar.Echo] = {
        let thisMac = ["ACCpromAdapterDaemon :9200", "Discord :6463", "launchd :8021", "node :3456", "Orca :64270",
                       "Warp :9277"]
        let localNetwork = ["mDNSResponder :5353", "sharingd :8770"]
        let network = ["ARDAgent :3283", "ControlCenter :5000", "ControlCenter :7000", "Orca :6768", "rapportd :57618",
                       "rapportd :57617", "rapportd :57387", "sshd :22", "screensharingd :5900", "smbd :445",
                       "AirPlayXPCHelper :7100", "postgres :5432", "nginx :8080", "node :3000", "ollama :11434",
                       "syncthing :22000", "remoted :49152"]
        func echoes(_ labels: [String], _ ring: ReachRadar.Ring) -> [ReachRadar.Echo] {
            labels.map { ReachRadar.Echo(id: "\($0)\(ring.rawValue)", label: $0, ring: ring) }
        }
        return echoes(thisMac, .thisMac) + echoes(localNetwork, .localNetwork) + echoes(network, .network)
    }()

    static func reachRadar(_ scene: ReachRadarScene) -> some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead("Erreichbarkeit", detail: "Wer diesen Mac erreichen kann", value: "17", finding: true,
                     expansion: .constant(scene.isExpanded))
            if scene.isExpanded {
                ReachRadar(echoes: reachEchoes, isExpanded: true).frame(maxHeight: .infinity)
            } else {
                ReachRadar(echoes: reachEchoes).frame(height: InstrumentSize.radar)
            }
        }
        .instrumentPanel()
        .padding(InstrumentSpacing.page)
        .instrumentBackground()
    }
}
