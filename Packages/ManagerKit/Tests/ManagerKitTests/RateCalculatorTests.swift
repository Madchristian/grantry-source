import Testing
@testable import ManagerKit

@Suite struct RateCalculatorTests {
    @Test func perSecondDividesGrowthByElapsedTime() {
        #expect(RateCalculator.perSecond(from: 100, to: 300, over: .seconds(2)) == 100)
    }

    @Test func perSecondIgnoresSinkingCounters() {
        #expect(RateCalculator.perSecond(from: 300, to: 100, over: .seconds(1)) == nil)
    }

    @Test func perSecondNeedsElapsedTime() {
        #expect(RateCalculator.perSecond(from: 0, to: 10, over: .zero) == nil)
    }

    @Test func coreLoadIsBusyShareOfTicks() {
        let before = CoreTicks(kind: .performance, busy: 100, idle: 900)
        let after = CoreTicks(kind: .performance, busy: 150, idle: 950)
        #expect(RateCalculator.load(from: before, to: after) == 0.5)
    }

    @Test func coreLoadWithoutTicksOrWithSinkingCountersIsUnknown() {
        let ticks = CoreTicks(kind: .efficiency, busy: 10, idle: 10)
        #expect(RateCalculator.load(from: ticks, to: ticks) == nil)
        #expect(RateCalculator.load(from: ticks, to: CoreTicks(kind: .efficiency, busy: 5, idle: 20)) == nil)
    }

    @Test func processLoadIsShareOfAllCores() {
        #expect(RateCalculator.processLoad(fromNanoseconds: 0, to: 2_000_000_000, over: .seconds(1), coreCount: 4) == 0.5)
    }

    @Test func processLoadIsCappedAtAllCores() {
        #expect(RateCalculator.processLoad(fromNanoseconds: 0, to: 8_000_000_000, over: .seconds(1), coreCount: 4) == 1)
    }

    @Test func processLoadNeedsCores() {
        #expect(RateCalculator.processLoad(fromNanoseconds: 0, to: 1, over: .seconds(1), coreCount: 0) == nil)
    }

    @Test func sumAddsTicksOfAllCores() {
        let sum = CoreTicks.sum([CoreTicks(kind: .performance, busy: 1, idle: 2),
                                 CoreTicks(kind: .efficiency, busy: 3, idle: 4)])
        #expect(sum == CoreTicks(kind: .unknown, busy: 4, idle: 6))
    }
}
