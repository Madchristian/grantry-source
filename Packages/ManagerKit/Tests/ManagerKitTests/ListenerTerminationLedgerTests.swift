import Foundation
import Testing
@testable import ManagerKit

@Suite struct ListenerTerminationLedgerTests {
    @Test func endedUntilSeenAgain() {
        let ledger = ListenerTerminationLedger(retention: 600)
        ledger.record("a", at: TestData.date)
        #expect(ledger.settleEndedIDs(at: TestData.date, seen: []) == ["a"])
        #expect(ledger.settleEndedIDs(at: TestData.date, seen: ["a"]).isEmpty)
        #expect(ledger.settleEndedIDs(at: TestData.date, seen: []).isEmpty)
    }

    @Test func expiresAfterRetention() {
        let ledger = ListenerTerminationLedger(retention: 600)
        ledger.record("a", at: TestData.date)
        #expect(ledger.settleEndedIDs(at: TestData.date.addingTimeInterval(600), seen: []) == ["a"])
        #expect(ledger.settleEndedIDs(at: TestData.date.addingTimeInterval(601), seen: []).isEmpty)
    }

    /// Ohne Vermerk entfiele ein fremder Lauscher spätestens nach der Frist für fremde Lauscher – länger muss der
    /// Vermerk nicht halten.
    @Test func defaultRetentionIsTheForeignGracePeriod() {
        let ledger = ListenerTerminationLedger()
        ledger.record("a", at: TestData.date)
        let limit = TestData.date.addingTimeInterval(Snapshot.foreignListenerGracePeriod)
        #expect(ledger.settleEndedIDs(at: limit, seen: []) == ["a"])
        #expect(ledger.settleEndedIDs(at: limit.addingTimeInterval(1), seen: []).isEmpty)
    }

    /// Eine Messung, die vor dem Vermerk begann, sah den Prozess womöglich noch lebend: Ihre Sichtung hebt den
    /// Vermerk nicht auf, und ein Vermerk aus ihrer Zukunft gilt nicht als abgelaufen.
    @Test func sightingFromAnEarlierMeasurementKeepsTheRecord() {
        let ledger = ListenerTerminationLedger(retention: 600)
        ledger.record("a", at: TestData.date.addingTimeInterval(1))
        #expect(ledger.settleEndedIDs(at: TestData.date, seen: ["a"]) == ["a"])
        #expect(ledger.settleEndedIDs(at: TestData.date.addingTimeInterval(2), seen: []) == ["a"])
        #expect(ledger.settleEndedIDs(at: TestData.date.addingTimeInterval(2), seen: ["a"]).isEmpty)
    }

    @Test func helperRefreshIsRequestedOncePerRecord() {
        let ledger = ListenerTerminationLedger()
        #expect(!ledger.takeHelperRefresh())
        ledger.record("a", at: TestData.date)
        #expect(ledger.takeHelperRefresh())
        #expect(!ledger.takeHelperRefresh())
    }
}
