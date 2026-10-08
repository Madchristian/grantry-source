import Testing
@testable import ManagerKit

@Suite struct CleanupHintsTests {
    private let gone = TestData.app("com.gone", presence: .missing)
    private let probablyGone = TestData.app("com.maybe", presence: .probablyMissing)

    @Test func flagsDeniedGrantsOfMissingAndProbablyMissingApps() {
        let snapshot = TestData.snapshot(grants: [
            TestData.grant(client: probablyGone, authValue: .denied),
            TestData.grant(client: gone, authValue: .denied),
        ])
        let hints = CleanupHints.evaluate(snapshot)
        #expect(hints.map(\.recordID) == ["user|kTCCServiceCamera|com.gone", "user|kTCCServiceCamera|com.maybe"])
        #expect(hints.allSatisfy {
            $0.message == "Eintrag einer entfernten App – kann in den Systemeinstellungen gelöscht werden"
        })
    }

    /// Erteilte Berechtigungen verwaister Apps sind Findings der `OrphanRule`, keine Aufräumhinweise.
    @Test func ignoresGrantedGrants() {
        let snapshot = TestData.snapshot(grants: [
            TestData.grant(client: gone, authValue: .allowed),
            TestData.grant(client: gone, authValue: .limited),
        ])
        #expect(CleanupHints.evaluate(snapshot).isEmpty)
    }

    @Test func ignoresPresentAndUnknownApps() {
        let snapshot = TestData.snapshot(grants: [
            TestData.grant(client: TestData.app("com.here"), authValue: .denied),
            TestData.grant(client: TestData.app("com.unknown", presence: .unknown), authValue: .denied),
        ])
        #expect(CleanupHints.evaluate(snapshot).isEmpty)
    }

    @Test func ignoresAppleComponents() {
        let apple = TestData.app("com.apple.gone", presence: .missing)
        let snapshot = TestData.snapshot(grants: [TestData.grant(client: apple, authValue: .denied)])
        #expect(CleanupHints.evaluate(snapshot).isEmpty)
    }

    @Test func isNotPartOfRiskEvaluation() {
        let snapshot = TestData.snapshot(grants: [TestData.grant(client: gone, authValue: .denied)])
        #expect(RiskEvaluator.standard.evaluate(snapshot).isEmpty)
        #expect(CleanupHints.evaluate(snapshot).count == 1)
    }
}
