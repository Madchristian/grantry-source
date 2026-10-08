import Foundation
import Testing
@testable import ManagerKit

@Suite struct ProcessTerminationPresentationTests {
    private static let node = RunningProcess(pid: 4242, uid: 501, executablePath: "/opt/homebrew/bin/node", startTime: 1)
    private static let request = ProcessTerminationRequest(listener: TestData.listener(), processes: [node])

    private func result(_ outcome: ActionOutcome, _ report: ProcessTerminationReport, force: Bool = false) -> ProcessTerminationResult {
        ProcessTerminationResult(request: Self.request, force: force, outcome: outcome, report: report)
    }

    @Test func doneNamesTheProgram() {
        let presentation = ActionOutcomePresentation.termination(result(.done, ProcessTerminationReport(ended: [Self.node])))
        #expect(presentation.text == "„node“ wurde beendet.")
        #expect(presentation.tone == .positive && presentation.details.isEmpty)
        #expect(ActionOutcomePresentation.termination(result(.done, ProcessTerminationReport(ended: [Self.node]), force: true)).text
            == "„node“ wurde sofort beendet.")
    }

    @Test func survivorsPointToSIGKILL() {
        let presentation = ActionOutcomePresentation.termination(
            result(.doneButUnverified("1 Prozess läuft noch."), ProcessTerminationReport(stillRunning: [Self.node]))
        )
        #expect(presentation.text == "1 Prozess läuft noch. „Sofort beenden (SIGKILL) …“ steht im Detail des Dienstes.")
        #expect(presentation.tone == .warning)
        #expect(presentation.details == ["PID 4242 läuft noch"])
    }

    @Test func survivorsOfSIGKILLGetNoHint() {
        let presentation = ActionOutcomePresentation.termination(
            result(.doneButUnverified("1 Prozess läuft auch nach dem sofortigen Beenden noch."),
                   ProcessTerminationReport(stillRunning: [Self.node]), force: true)
        )
        #expect(presentation.text == "1 Prozess läuft auch nach dem sofortigen Beenden noch.")
    }

    @Test func failuresAreListedPerPID() {
        let failure = ProcessTerminationFailure(process: Self.node, message: "Keine Berechtigung, Prozess 4242 zu beenden")
        let presentation = ActionOutcomePresentation.termination(
            result(.failed("Prozess nicht beendet: Keine Berechtigung, Prozess 4242 zu beenden"), ProcessTerminationReport(failures: [failure]))
        )
        #expect(presentation.tone == .critical)
        #expect(presentation.details == ["PID 4242: Keine Berechtigung, Prozess 4242 zu beenden"])
    }
}
