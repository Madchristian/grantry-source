import Testing
@testable import ManagerKit

@MainActor
@Suite struct NetworkProcessRatesTests {
    private static let browser = ProcessKey(pid: 610, startTime: 1)
    private static let curl = ProcessKey(pid: 700, startTime: 2)

    private func report(history: [TrafficRate] = [.zero]) -> TrafficReport {
        let processes = [
            ProcessActivity(key: Self.browser, shortName: "Safari", rate: TrafficRate(download: 2_000, upload: 500),
                            transferred: .zero, connections: [], isGone: false),
            ProcessActivity(key: Self.curl, shortName: "curl", rate: .zero, transferred: .zero, connections: [],
                            isGone: true),
        ]
        return TrafficReport(processes: processes, total: TrafficRate(download: 2_000, upload: 500), history: history,
                             skippedLineCount: 0)
    }

    @Test func ratesOfActiveProcessesWhileMeasuring() {
        #expect(NetworkActivityModel.processRates(status: .running, report: report()) == [Self.browser: 2_500])
    }

    @Test func noRatesBeforeTheSecondMeasurementOrWithoutSampler() {
        #expect(NetworkActivityModel.processRates(status: .running, report: report(history: [])) == nil)
        #expect(NetworkActivityModel.processRates(status: .idle, report: report()) == nil)
        #expect(NetworkActivityModel.processRates(status: .failed(.unavailable(reason: "x")), report: report()) == nil)
    }

    @Test func modelWithoutRunHasNoRates() {
        #expect(NetworkActivityModel().processRates == nil)
    }
}
