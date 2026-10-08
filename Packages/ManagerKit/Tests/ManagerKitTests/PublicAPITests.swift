import Testing
import ManagerKit

/// Nutzt bewusst nur öffentliche API (ohne `@testable`), damit die App darauf zugreifen kann.
@Suite struct PublicAPITests {
    @Test func authValueIsGrantedIsPublic() {
        #expect(AuthValue.allowed.isGranted)
        #expect(AuthValue.limited.isGranted)
        #expect(!AuthValue.denied.isGranted)
        #expect(!AuthValue.unknown(7).isGranted)
    }

    /// Was die Ansicht „Aktivität“ der App braucht, ist öffentlich.
    @MainActor @Test func networkActivityAPIIsPublic() {
        let model = NetworkActivityModel()
        model.filter.onlyActive = false
        model.query = "curl"
        #expect(model.status == .idle)
        #expect(model.rows.isEmpty)
        #expect(model.notice == nil)
        #expect(TrafficFormat.rate(1500) == "1,5 KB/s")
        #expect(NetworkActivityPresenter.defaultSortOrder.count == 1)
    }
}
