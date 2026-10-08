import Testing
import Foundation
import TestSupport
@testable import GrantryShared

@Suite struct AdminMembershipTests {
    @Test(.enabled(if: CurrentUser.isAdministrator, "Nur für Benutzer in der Gruppe admin"))
    func acceptsAdministrator() {
        #expect(AdminMembership.isAdministrator(getuid()))
    }

    @Test func rejectsNobody() {
        #expect(!AdminMembership.isAdministrator(uid_t(bitPattern: -2)))
    }
}
