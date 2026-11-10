import Foundation
import Testing
@testable import GrantryCharts

@Suite struct ScrubTests {
    @Test func dragShiftsBackInTime() {
        var scrub = Scrub()
        scrub.drag(by: 200, width: 400, window: 60)
        #expect(scrub.offset(at: .now) == 30)
    }

    @Test func dragForwardDoesNotGoIntoFuture() {
        var scrub = Scrub()
        scrub.drag(by: -200, width: 400, window: 60)
        #expect(scrub.offset(at: .now) == 0)
    }

    @Test func releaseSpringsBackToPresent() {
        var scrub = Scrub()
        scrub.drag(by: 200, width: 400, window: 60)
        let release = Date(timeIntervalSinceReferenceDate: 0)
        scrub.release(at: release)
        #expect(scrub.offset(at: release) == 30)
        #expect(scrub.offset(at: release.addingTimeInterval(2)) < 0.01)
    }
}
