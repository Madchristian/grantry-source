import SwiftUI
@testable import GrantryCharts

/// Karte „Ziele“ (Netzwerk › Verbindungen): Bogenfächer von diesem Mac zu den Ländern seiner Verbindungen – mit
/// wenigen Ländern, mit vielen (der Rest als „+n“), nur mit lokalen Gegenstellen und auf die ganze Seite vergrößert
/// mit den Programmen als zweiter Stufe; mit Zielfilter (#633) ein gewähltes Land, der gewählte Sammel-Ast und ein
/// gewähltes Land auf der vergrößerten Seite.
@MainActor
extension SnapshotGallery {
    enum ArcFanScene: String, CaseIterable, Sendable {
        case few = "wenige"
        case many = "viele"
        case localOnly = "nur-lokal"
        case page = "seite"
        case picked = "gefiltert"
        case pickedSummary = "gefiltert-sammel"
        case pickedPage = "seite-gefiltert"

        var isExpanded: Bool { self == .page || self == .pickedPage }

        /// Äste des Zielfilters: ein Land bzw. alle, die der Sammel-Ast „+n“ vertritt.
        var picked: Set<ArcFan.Branch.ID> {
            switch self {
            case .few, .many, .localOnly, .page: []
            case .picked, .pickedPage: ["Irland"]
            case .pickedSummary: Set(branches.dropFirst(ArcFanLayout.compactCapacity - 1).map(\.id))
            }
        }

        var size: CGSize {
            isExpanded ? CGSize(width: 1100, height: 760) : CGSize(width: InstrumentSize.columnRadar, height: 372)
        }

        var branches: [ArcFan.Branch] {
            switch self {
            case .few: Array(SnapshotGallery.fanCountries.prefix(3)) + SnapshotGallery.fanHome
            case .many, .page, .pickedSummary, .pickedPage: SnapshotGallery.fanCountries + SnapshotGallery.fanHome
            case .picked: Array(SnapshotGallery.fanCountries.prefix(3)) + SnapshotGallery.fanHome
            case .localOnly: SnapshotGallery.fanHome
            }
        }
    }

    nonisolated static let fanCountries: [ArcFan.Branch] = {
        let countries: [(String, Int, [(String, Int)])] = [
            ("Vereinigte Staaten", 14, [("Safari", 6), ("Mail", 3), ("Firefox", 2), ("Discord", 1), ("node", 1), ("curl", 1)]),
            ("Deutschland", 9, [("Safari", 5), ("Firefox", 4)]),
            ("Irland", 6, [("Mail", 4), ("Safari", 2)]),
            ("Niederlande", 4, [("Firefox", 4)]),
            ("Vereinigtes Königreich", 3, [("Safari", 2), ("Discord", 1)]),
            ("Schweden", 3, [("Spotify", 3)]),
            ("Frankreich", 2, [("Firefox", 2)]),
            ("Japan", 2, [("Safari", 1), ("node", 1)]),
            ("Singapur", 1, [("Firefox", 1)]),
            ("Brasilien", 1, [("Safari", 1)]),
            ("Kanada", 1, [("Mail", 1)]),
            ("Demokratische Republik Kongo", 1, [("curl", 1)]),
        ]
        return countries.map { name, weight, programs in
            ArcFan.Branch(id: name, label: name, weight: weight,
                          leaves: programs.map { ArcFan.Leaf(id: "\(name)-\($0.0)", label: $0.0, weight: $0.1) })
        } + [ArcFan.Branch(id: "unbekannt", label: "Land unbekannt", weight: 2, tone: .neutral,
                           leaves: [ArcFan.Leaf(id: "unbekannt-Mail", label: "Mail", weight: 2)])]
    }()

    /// Gegenstellen ohne Land: das lokale Netz (nur eingehend, gestrichelt) und dieser Mac.
    nonisolated static let fanHome: [ArcFan.Branch] = [
        ArcFan.Branch(id: "lokal", label: "Lokales Netz", weight: 3, tone: .positive, isDashed: true,
                      leaves: [ArcFan.Leaf(id: "lokal-node", label: "node", weight: 2),
                               ArcFan.Leaf(id: "lokal-ssh", label: "sshd", weight: 1)]),
        ArcFan.Branch(id: "mac", label: "Dieser Mac", weight: 2, tone: .positive,
                      leaves: [ArcFan.Leaf(id: "mac-postgres", label: "postgres", weight: 2)]),
    ]

    static func arcFan(_ scene: ArcFanScene) -> some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead("Ziele", detail: "Wohin dieser Mac verbindet", value: "\(scene.branches.count)",
                     expansion: .constant(scene.isExpanded))
            if scene.isExpanded {
                ArcFan(branches: scene.branches, originSymbol: "laptopcomputer", title: "Ziele", picked: scene.picked,
                       isExpanded: true)
                    .frame(maxHeight: .infinity)
            } else {
                ArcFan(branches: scene.branches, originSymbol: "laptopcomputer", title: "Ziele", selection: "Deutschland",
                       picked: scene.picked)
                    .frame(height: InstrumentSize.radar)
            }
        }
        .instrumentPanel()
        .padding(InstrumentSpacing.page)
        .instrumentBackground()
    }
}
