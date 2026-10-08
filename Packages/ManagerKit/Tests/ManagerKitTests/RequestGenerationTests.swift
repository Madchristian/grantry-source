import Testing
import ManagerKit

@Suite struct RequestGenerationTests {
    @Test func onlyTheNewestRequestIsCurrent() {
        var generation = RequestGeneration()
        let first = generation.begin()
        #expect(generation.isCurrent(first))
        let second = generation.begin()
        #expect(!generation.isCurrent(first))
        #expect(generation.isCurrent(second))
    }

    @Test func invalidateMakesEveryRunningRequestStale() {
        var generation = RequestGeneration()
        let request = generation.begin()
        generation.invalidate()
        #expect(!generation.isCurrent(request))
    }
}
