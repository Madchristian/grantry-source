import Foundation
import Testing
@testable import ManagerKit

@Suite struct SnapshotNetworkCarryTests {
    private let minute: TimeInterval = 60
    private let ownUID: UInt32 = 501

    private func carried(
        _ previous: [NetworkListener], into current: [NetworkListener] = [], after interval: TimeInterval,
        isLimited: Bool = false
    ) -> [NetworkListener] {
        TestData.networkSnapshot(current, at: TestData.date.addingTimeInterval(interval))
            .carryingForwardListeners(from: TestData.networkSnapshot(previous), currentUID: ownUID, isLimited: isLimited)
            .networkListeners
    }

    @Test func missingListenerIsKeptWithinGracePeriod() {
        let node = TestData.listener()
        #expect(carried([node], after: 4 * minute) == [node])
    }

    @Test func missingListenerIsDroppedAfterGracePeriod() {
        #expect(carried([TestData.listener()], after: 5 * minute + 1).isEmpty)
    }

    @Test func ownListenerIsDroppedAfterSixMinutes() {
        #expect(carried([TestData.listener()], after: 6 * minute).isEmpty)
    }

    @Test func graceCountsFromLastSighting() {
        let seenLong = TestData.listener(lastSeen: TestData.date.addingTimeInterval(-10 * minute))
        #expect(carried([seenLong], after: 0).isEmpty)
    }

    /// Der Helper liest fremde Sockets nur alle 15 min: Ein kurz fehlender root-Dienst darf dann nicht wegfallen.
    @Test func foreignListenerIsKeptWithinHelperInterval() {
        let root = TestData.listener("/usr/local/sbin/daemon", uid: 0)
        #expect(carried([root], after: 15 * minute) == [root])
    }

    @Test func foreignListenerIsDroppedAfterForeignGracePeriod() {
        let root = TestData.listener("/usr/local/sbin/daemon", uid: 0)
        #expect(carried([root], after: 21 * minute).isEmpty)
    }

    @Test func firstSeenIsKept() {
        let later = TestData.date.addingTimeInterval(minute)
        let carried = carried([TestData.listener()], into: [TestData.listener(firstSeen: later, lastSeen: later)],
                              after: minute)
        #expect(carried.map(\.firstSeenAt) == [TestData.date])
        #expect(carried.map(\.lastSeenAt) == [later])
    }

    @Test func otherUsersAreKeptWhenLimited() {
        let root = TestData.listener("/usr/local/sbin/daemon", uid: 0)
        #expect(carried([root, TestData.listener()], after: 60 * minute, isLimited: true) == [root])
    }

    /// Uhrsprung rückwärts: Der Lauscher bleibt, bis die Uhr aufgeholt hat.
    @Test func clockJumpingBackKeepsListener() {
        let node = TestData.listener()
        #expect(carried([node], after: -60 * minute) == [node])
    }

    @Test func duplicateIDsInPreviousAreAppendedOnce() {
        let first = TestData.listener(addresses: ["0.0.0.0"])
        let duplicate = TestData.listener(addresses: ["127.0.0.1"])
        #expect(carried([first, duplicate], after: minute) == [first])
    }

    @Test func isIdempotent() {
        let previous = TestData.networkSnapshot([TestData.listener()])
        let current = TestData.networkSnapshot([], at: TestData.date.addingTimeInterval(minute))
        let once = current.carryingForwardListeners(from: previous, currentUID: ownUID, isLimited: false)
        #expect(once.carryingForwardListeners(from: previous, currentUID: ownUID, isLimited: false) == once)
    }

    /// „Prozess beenden …“: Beendete Lauscher fallen sofort weg – auch fremde bei eingeschränktem Scan.
    @Test func endedListenersAreNotCarriedForward() {
        let node = TestData.listener()
        let root = TestData.listener("/usr/local/sbin/daemon", uid: 0)
        let result = TestData.networkSnapshot([], at: TestData.date.addingTimeInterval(minute))
            .carryingForwardListeners(from: TestData.networkSnapshot([node, root]), currentUID: ownUID, isLimited: true,
                                      ended: [node.id, root.id])
        #expect(result.networkListeners.isEmpty)
    }

    @Test func endedIDDoesNotHideAListenerSeenAgain() {
        let node = TestData.listener()
        let result = TestData.networkSnapshot([node], at: TestData.date.addingTimeInterval(minute))
            .carryingForwardListeners(from: TestData.networkSnapshot([node]), currentUID: ownUID, isLimited: false,
                                      ended: [node.id])
        #expect(result.networkListeners.map(\.id) == [node.id])
    }
}
