import Testing
import TestSupport
@testable import ManagerKit

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ForeignProcessUsageConsumerTests {
    private static let command = "/bin/ps -axo pid=,uid=,pcpu=,rss="

    private func model() -> ForeignProcessUsageModel {
        let runner = MockCommandRunner([Self.command: CommandResult(exitCode: 0, stdout: "88 88 50.0 2\n")])
        return ForeignProcessUsageModel(runner: runner, coreCount: 2,
                                        sleep: { _ in try await Task.sleep(for: .seconds(60)) })
    }

    /// Tab-Wechsel „Prozesse“ → „Details“: Der neue Tab erscheint, bevor der alte verschwindet.
    @Test func keepsMeasuringWhileAnotherTabStillConsumes() {
        let model = model()
        model.start(for: .processesTab)
        model.start(for: .detailsTab)
        model.stop(for: .processesTab)
        #expect(model.isRunning)
        model.stop(for: .detailsTab)
        #expect(!model.isRunning)
    }

    @Test func stoppingAnAbsentConsumerKeepsTheOther() {
        let model = model()
        model.start(for: .detailsTab)
        model.stop(for: .processesTab)
        #expect(model.isRunning)
        model.stop(for: .detailsTab)
    }
}
