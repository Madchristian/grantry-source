import Testing
@testable import ManagerKit

@Suite struct ServiceResetTests {
    private let orphan = TestData.grant("kTCCServiceAccessibility", client: TestData.app("ai.gone", presence: .missing), scope: .system)
    private let probablyGone = TestData.grant("kTCCServiceAccessibility", client: TestData.app("bot.gone", presence: .probablyMissing), scope: .system)
    private let installed = TestData.grant("kTCCServiceAccessibility", scope: .system)
    private let apple = TestData.grant(
        "kTCCServiceAccessibility", client: TestData.app("com.apple.Gone", signing: SigningInfo(kind: .apple), presence: .missing), scope: .system
    )
    private let otherService = TestData.grant("kTCCServiceScreenCapture", client: TestData.app("ai.gone", presence: .missing), scope: .system)

    @Test func splitsTheServiceIntoOrphansAndCollateral() throws {
        let snapshot = TestData.snapshot(grants: [orphan, probablyGone, installed, apple, otherService])
        let reset = try #require(ServiceReset(service: "kTCCServiceAccessibility", in: snapshot))
        #expect(reset.orphans == [orphan, probablyGone])
        // Apple-Komponenten gelten nie als verwaist, verlieren die Berechtigung aber mit.
        #expect(reset.collateral == [installed, apple])
        #expect(reset.source == .tccSystem)
        #expect(reset.orphanNames == ["ai.gone", "bot.gone"])
        #expect(reset.id == ServiceReset.recordID(for: "kTCCServiceAccessibility"))
    }

    @Test func isOnlyOfferedWhenTheServiceHasAnOrphan() {
        #expect(ServiceReset(service: "kTCCServiceAccessibility", in: TestData.snapshot(grants: [installed, apple])) == nil)
        #expect(ServiceReset(service: "kTCCServiceCamera", in: TestData.snapshot(grants: [orphan])) == nil)
    }

    @Test func knowsWhetherItAffectsAGivenApp() throws {
        let reset = try #require(ServiceReset(service: "kTCCServiceAccessibility", in: TestData.snapshot(grants: [orphan, installed])))
        #expect(reset.affects(bundleID: "us.zoom.xos"))
        #expect(!reset.affects(bundleID: "ai.gone"))
        #expect(!reset.affects(bundleID: nil))
    }
}
