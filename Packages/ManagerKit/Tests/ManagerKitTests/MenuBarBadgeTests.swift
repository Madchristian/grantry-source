import Testing
import ManagerKit

@Suite struct MenuBarBadgeTests {
    @Test(arguments: [
        (-1, MenuBarBadge.none), (0, .none), (1, .count(1)), (9, .count(9)), (10, .dot), (250, .dot),
    ])
    func badgeForUnreadCount(unread: Int, badge: MenuBarBadge) {
        #expect(MenuBarBadge(unreadCount: unread) == badge)
    }

    @Test func textOnlyForCounts() {
        #expect(MenuBarBadge.count(3).text == "3")
        #expect(MenuBarBadge.dot.text == nil)
        #expect(MenuBarBadge.none.text == nil)
    }

    @Test func accessibilityLabelNamesTheExactCount() {
        #expect(MenuBarBadge.accessibilityLabel(unreadCount: 0) == "Grantry")
        #expect(MenuBarBadge.accessibilityLabel(unreadCount: 1) == "Grantry, 1 ungelesene Änderung")
        #expect(MenuBarBadge.accessibilityLabel(unreadCount: 42) == "Grantry, 42 ungelesene Änderungen")
    }
}
