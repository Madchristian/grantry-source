import Testing
import ManagerKit

/// Kopf und Zusatzzeilen des Onboardings im Lagebild (LB-5.3, #554; Spec 2026-11-10 § 11.5 d und Korrektur).
@Suite struct OnboardingSummaryTests {
    private static let complete = SetupStatus(
        fullDiskAccess: true, helper: .ready, notifications: .authorized, launchAtLogin: .enabled
    )
    private static let missing = SetupStatus(
        fullDiskAccess: false, helper: .notInstalled, notifications: .notDetermined, launchAtLogin: .disabled
    )

    private func summary(_ status: SetupStatus, updates: Bool = true,
                         baseline: OnboardingSummary.Baseline = .pending) -> OnboardingSummary {
        OnboardingSummary(checklist: SetupChecklist(status), checksUpdatesDaily: updates, baseline: baseline)
    }

    @Test func countsTheFourSetupStepsPlusUpdatesAndBaseline() {
        let summary = summary(Self.missing)
        #expect(summary.stepCount == 6)
        #expect(summary.stepsText == "6 Schritte")
        // Die Entscheidung über Updates ist mit dem Schalter getroffen, in beide Richtungen.
        #expect(summary.doneCount == 1)
        #expect(summary.progressText == "1 von 6 erledigt")
        #expect(self.summary(Self.missing, updates: false).doneCount == 1)
    }

    @Test func openStepsLeadTheVerdictWithAnOpenShield() {
        let summary = summary(Self.missing)
        #expect(summary.verdict == OnboardingSummary.Status(text: "4 offen", tone: .finding))
        #expect(summary.shield == .open)
    }

    @Test func runningBaselineScan() {
        let summary = summary(Self.complete, baseline: .scanning)
        #expect(summary.verdict == OnboardingSummary.Status(text: "Scan läuft", tone: .running))
        #expect(summary.baselineStatus == OnboardingSummary.Status(text: "läuft", tone: .running))
        #expect(summary.progressText == "5 von 6 erledigt")
        #expect(summary.shield == .open)
    }

    @Test func readyBeforeTheBaselineKeepsTheShieldOpen() {
        let summary = summary(Self.complete)
        #expect(summary.verdict == OnboardingSummary.Status(text: "bereit", tone: .positive))
        #expect(summary.baselineStatus == OnboardingSummary.Status(text: "Folgt nach „Fertig“", tone: .neutral))
        #expect(summary.shield == .open)
    }

    @Test func savedBaselineJudgesTheSetup() {
        let done = summary(Self.complete, baseline: .saved)
        #expect(done.shield == .judged(finding: false))
        #expect(done.progressText == "6 von 6 erledigt")
        #expect(done.baselineStatus == OnboardingSummary.Status(text: "Ausgangsbasis gespeichert", tone: .positive))
        let open = summary(SetupStatus(fullDiskAccess: true, helper: .ready, notifications: .denied,
                                       launchAtLogin: .enabled), baseline: .saved)
        #expect(open.shield == .judged(finding: true))
        #expect(open.verdict == OnboardingSummary.Status(text: "1 offen", tone: .finding))
    }

    @Test func uncheckedSetupIsNotReady() {
        let summary = summary(SetupStatus())
        #expect(summary.verdict == OnboardingSummary.Status(text: "wird geprüft", tone: .neutral))
        #expect(summary.shield == .open)
    }

    @Test func updatesChoice() {
        #expect(summary(Self.missing).updatesStatus == OnboardingSummary.Status(text: "Täglich prüfen", tone: .positive))
        #expect(summary(Self.missing, updates: false).updatesStatus
            == OnboardingSummary.Status(text: "Nicht prüfen", tone: .neutral))
    }

    @Test func updatesRowSplitsThePrivacyNoteIntoReasonAndRest() {
        #expect(OnboardingSummary.updatesReason
            == "Grantry fragt einmal täglich bei grantry.cstrube.de nach einer neuen Version.")
        #expect(OnboardingSummary.updatesExplanation
            == "Dabei werden nur die Version von Grantry, die macOS-Version und die Mac-Architektur übertragen.")
    }
}
