import Foundation
import Testing
@testable import ManagerKit

/// Regel „neuer aus dem Netz erreichbarer Dienst“ (Spec §5.1, TM-12.4): ein Befund aus dem Verlauf, keine Messreihe.
@Suite struct ExposedServiceRuleTests {
    private typealias F = FindingFixtures
    private static let uid: UInt32 = 501

    private func change(_ kind: ChangeEvent.Kind, _ listener: NetworkListener, before: NetworkListener? = nil,
                        at offset: TimeInterval = 0) -> ChangeEvent {
        ChangeEvent(kind: kind, before: kind == .added ? nil : .networkListener(before ?? listener),
                    after: kind == .removed ? nil : .networkListener(listener), detectedAt: F.time(offset))
    }

    private func findings(_ changes: [ChangeEvent]) -> [SystemFinding] {
        FindingRules.exposedServiceFindings(in: changes, currentUID: Self.uid)
    }

    @Test func newExposedServiceIsAnInstantFinding() throws {
        let finding = try #require(findings([change(.added, TestData.listener(uid: Self.uid), at: 30)]).first)
        #expect(finding.kind == .exposedService)
        #expect(finding.tone == .finding)
        #expect(finding.start == F.time(30))
        #expect(finding.end == F.time(30))
        #expect(!finding.isOngoing)
        #expect(finding.reason == "node ist neu aus dem Netz erreichbar.")
        #expect(finding.watchbookEvent.subject == .program("node"))
    }

    /// Wechsel von „nur dieser Mac“ ins Netz zählt wie ein neuer Dienst.
    @Test func becomingReachableFromTheNetworkCounts() {
        let local = TestData.listener(uid: Self.uid, addresses: ["127.0.0.1"])
        let exposed = TestData.listener(uid: Self.uid, addresses: ["0.0.0.0"])
        #expect(findings([change(.modified, exposed, before: local)]).count == 1)
        #expect(findings([change(.modified, local, before: exposed)]).isEmpty)
        #expect(findings([change(.modified, exposed, before: exposed)]).isEmpty)
    }

    /// Wie die Kachel „Von außen erreichbar“: nur lokal, beendet, Dienste von macOS und vermutliche Clients nicht.
    @Test func ignoresLocalRemovedAppleAndClientListeners() {
        let local = TestData.listener(uid: Self.uid, addresses: ["127.0.0.1"])
        let apple = TestData.listener("/usr/libexec/rapportd", uid: 501, signing: SigningInfo(kind: .apple))
        let client = TestData.listener("/Applications/Browser.app/Contents/MacOS/Browser", transport: .udp, port: nil,
                                       signing: TestData.developerSigning)
        let other = ChangeEvent(kind: .added, before: nil, after: .autostartItem(TestData.item()),
                                detectedAt: F.start)
        #expect(findings([
            change(.added, local), change(.removed, TestData.listener()), change(.added, apple),
            change(.added, client), other,
        ]).isEmpty)
    }

    /// Andere Konten bleiben ohne Namen (Spec §4.5).
    @Test func otherAccountsStayAnonymous() throws {
        let finding = try #require(findings([change(.added, TestData.listener("/Users/other/bin/tool", uid: 502))])
            .first)
        #expect(finding.watchbookEvent.subject == .otherAccounts)
        #expect(!finding.reason.contains("tool"))
        #expect(finding.reason == "Ein Dienst eines anderen Kontos ist neu aus dem Netz erreichbar.")
    }

    /// Stabil über Dienst und Zeitpunkt: Erneutes Auswerten ergibt dieselben IDs, zwei Dienste im selben Scan zwei.
    @Test func identityIsStablePerServiceAndTime() {
        let changes = [change(.added, TestData.listener(port: 3000)), change(.added, TestData.listener(port: 4000))]
        let first = findings(changes)
        #expect(first.count == 2)
        #expect(Set(first.map(\.id)).count == 2)
        #expect(findings(changes).map(\.id) == first.map(\.id))
    }

    /// Keine Messreihe: Die Regeln über Wachbuch-Punkte ergeben diesen Befund nie.
    @Test func pointRulesNeverProduceIt() {
        let points = F.points(F.values([(1, 60)])) { values, value in values[.cpuTotal] = value }
        #expect(FindingRules.findings(of: .exposedService, in: points).isEmpty)
    }
}
