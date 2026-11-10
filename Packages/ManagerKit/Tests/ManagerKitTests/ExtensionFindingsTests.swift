import Foundation
import Testing
@testable import ManagerKit

/// Befunde der Erweiterungen als `SystemFinding` für Lagezeile und Wachbuch (#390).
struct ExtensionFindingsTests {
    private typealias R = ExtensionRiskRulesTests

    @Test func findingsBecomeSystemFindingsWithToneAndSubject() {
        let kext = R.record(.kernelExtension, bundleID: "com.example.kext", state: .loaded,
                            signing: SigningInfo(kind: .developerID, teamID: "TEAM1"))
        let unsigned = R.record(.kernelExtension, bundleID: "com.example.unsigned", name: "Unsigned", state: .loaded,
                                signing: SigningInfo(kind: .unsigned))
        let snapshot = R.snapshot(kext, unsigned)
        let findings = SystemFinding.extensionFindings(RiskEvaluator.standard.evaluate(snapshot), in: snapshot.extensions)
        #expect(findings.map(\.kind) == [.extensionRisk, .extensionRisk])
        #expect(findings.map(\.tone) == [.finding, .critical])
        #expect(findings.map(\.subject) == [
            .systemExtension(identifier: kext.id, name: "Tool"),
            .systemExtension(identifier: unsigned.id, name: "Unsigned"),
        ])
        #expect(findings.first?.reason == "Tool läuft im Kern – auf Apple Silicon nur mit reduzierter Sicherheit.")
        #expect(findings.allSatisfy { $0.isOngoing && $0.start == kext.firstSeenAt })
    }

    /// Hinweise und Reste sind keine Befunde; je Erweiterung zählt nur der schwerste Befund.
    @Test func onlyTheStrongestFindingPerExtensionCounts() {
        let kext = R.record(.kernelExtension, state: .loaded, signing: SigningInfo(kind: .adHoc), owner: .missing)
        let note = R.record(.endpointSecurity, bundleID: "com.example.es")
        let video = R.record(.videoPlugin, bundleID: "com.example.dal", state: .installed,
                             signing: SigningInfo(kind: .developerID, teamID: "TEAM1"))
        let snapshot = R.snapshot(kext, note, video)
        let risks = RiskEvaluator.standard.evaluate(snapshot)
        #expect(risks.count == 4)
        let findings = SystemFinding.extensionFindings(risks, in: snapshot.extensions)
        #expect(findings.count == 1)
        #expect(findings.first?.tone == .critical)
        #expect(findings.first?.reason == "Tool läuft im Kern und ist nur ad hoc signiert.")
    }

    @Test func acceptedExtensionsAreNoSystemFindings() {
        let kext = R.record(.kernelExtension, state: .loaded, signing: SigningInfo(kind: .unsigned))
        let snapshot = R.snapshot(kext)
        let risks = RiskEvaluator.standard.evaluate(snapshot)
        #expect(SystemFinding.extensionFindings(risks, in: snapshot.extensions, acceptedIDs: [kext.id]).isEmpty)
    }

    /// Die ID bleibt über Scans gleich, damit das Wachbuch den laufenden Eintrag ersetzt statt zu verdoppeln.
    @Test func identifierIsStableAcrossScans() {
        let first = R.record(.kernelExtension, state: .loaded, signing: SigningInfo(kind: .unsigned))
        var later = first
        later.version = "2.0"
        let ids = [first, later].map { record in
            let snapshot = R.snapshot(record)
            return SystemFinding.extensionFindings(RiskEvaluator.standard.evaluate(snapshot), in: snapshot.extensions)
                .map(\.id)
        }
        #expect(ids[0] == ids[1])
        #expect(ids[0].count == 1)
    }

    /// Erweiterungen sind keine Programme: Im Wachbuch stehen sie ohne Verursacher, mit dem Grund als Zusammenfassung.
    @Test func watchbookEventCarriesReasonWithoutSubject() throws {
        let kext = R.record(.kernelExtension, state: .loaded, signing: SigningInfo(kind: .unsigned))
        let snapshot = R.snapshot(kext)
        let finding = try #require(
            SystemFinding.extensionFindings(RiskEvaluator.standard.evaluate(snapshot), in: snapshot.extensions).first)
        let event = finding.watchbookEvent
        #expect(event.type == "extension.risk")
        #expect(event.subject == nil)
        #expect(event.summary == finding.reason)
    }

    /// Die Messregeln kennen die Art nicht: Sie ergibt aus Messreihen nie einen Befund.
    @Test func measuredRulesIgnoreExtensionKind() {
        #expect(FindingRules.findings(of: .extensionRisk, in: []).isEmpty)
        #expect(FindingThresholds.standard.rule(for: .extensionRisk).minimumDuration == 0)
    }
}
