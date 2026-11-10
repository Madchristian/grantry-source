import Testing
@testable import ManagerKit

@MainActor
@Suite struct PresentationCacheTests {
    @Test func buildsOncePerKey() {
        let cache = PresentationCache<Int, String>()
        var builds = 0
        let make = { (key: Int) in
            cache.value(for: key) {
                builds += 1
                return "Stand \(key)"
            }
        }
        #expect(make(1) == "Stand 1")
        #expect(make(1) == "Stand 1")
        #expect(builds == 1)
        #expect(make(2) == "Stand 2")
        #expect(make(1) == "Stand 1")
        #expect(builds == 3)
    }
}
