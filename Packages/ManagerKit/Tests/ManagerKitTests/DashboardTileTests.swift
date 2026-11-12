import Foundation
import Testing
@testable import ManagerKit

/// Die fünf Zählkacheln der Übersicht (LB-3.2, #544; Spec 2026-11-10 § 11.3 a): Zahl, kurzes Detail und Betonung – wie
/// heute dieselben Zahlen und Sprünge.
@Suite struct DashboardTileTests {
    private func tiles(_ facts: DashboardTile.Facts) -> [DashboardTile.Kind: DashboardTile] {
        Dictionary(uniqueKeysWithValues: DashboardTile.tiles(facts).map { ($0.kind, $0) })
    }

    @Test func fiveTilesInFixedOrder() {
        #expect(DashboardTile.tiles(DashboardTile.Facts()).map(\.kind)
            == [.appsWithAccess, .newEntries, .flagged, .security, .exposed])
    }

    @Test func flaggedNamesHighAndMediumOrSaysCalm() {
        let flagged = tiles(DashboardTile.Facts(criticalEntries: 1, reviewEntries: 1, hints: 2))[.flagged]
        #expect(flagged?.value == 2)
        #expect(flagged?.detail == "1 hoch · 1 mittel")
        #expect(flagged?.emphasis == .finding)
        let hintsOnly = tiles(DashboardTile.Facts(hints: 2))[.flagged]
        #expect(hintsOnly?.value == 0)
        #expect(hintsOnly?.detail == "keine Befunde · 2 Hinweise")
        #expect(hintsOnly?.emphasis == .calm)
        #expect(tiles(DashboardTile.Facts())[.flagged]?.detail == "keine Befunde")
    }

    @Test func securityTellsOpenPointsOrState() {
        #expect(tiles(DashboardTile.Facts(openSecurityChecks: 1, securityState: .critical))[.security]?.detail
            == "1 Punkt offen")
        #expect(tiles(DashboardTile.Facts(openSecurityChecks: 2, securityState: .warning))[.security]?.emphasis
            == .finding)
        #expect(tiles(DashboardTile.Facts(securityState: .good))[.security]?.detail == "alles geschützt")
        #expect(tiles(DashboardTile.Facts(securityState: .good))[.security]?.emphasis == .calm)
        #expect(tiles(DashboardTile.Facts(securityState: .unknown))[.security]?.detail == "nicht alle Prüfungen möglich")
        #expect(tiles(DashboardTile.Facts(securityState: .unknown))[.security]?.emphasis == .plain)
        #expect(tiles(DashboardTile.Facts())[.security]?.detail == "noch nicht geprüft")
    }

    @Test func exposedAndNewEntries() {
        let some = tiles(DashboardTile.Facts(newEntries: 3, exposedServices: 2))
        #expect(some[.exposed]?.detail == "Dienste nehmen Verbindungen an")
        #expect(some[.exposed]?.emphasis == .finding)
        #expect(some[.newEntries]?.emphasis == .new)
        #expect(tiles(DashboardTile.Facts(exposedServices: 1))[.exposed]?.detail == "Dienst nimmt Verbindungen an")
        let none = tiles(DashboardTile.Facts())
        #expect(none[.exposed]?.detail == "keine Dienste")
        #expect(none[.exposed]?.emphasis == .calm)
        #expect(none[.newEntries]?.emphasis == .plain)
        #expect(none[.appsWithAccess]?.emphasis == .plain)
    }
}
