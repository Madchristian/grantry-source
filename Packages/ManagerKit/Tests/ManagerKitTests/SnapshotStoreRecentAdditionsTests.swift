import Foundation
import Testing
@testable import ManagerKit

@Suite("SnapshotStore.additions(since:)")
struct SnapshotStoreRecentAdditionsTests {
    private func event(_ kind: ChangeEvent.Kind, label: String, at offset: TimeInterval) -> ChangeEvent {
        ChangeEvent(
            kind: kind, before: nil, after: .autostartItem(TestData.item(label)),
            detectedAt: TestData.date.addingTimeInterval(offset)
        )
    }

    private func offsets(_ events: [HistoryEvent]) -> [TimeInterval] {
        events.map { $0.event.detectedAt.timeIntervalSince(TestData.date) }
    }

    @Test func emptyStoreHasNoAdditions() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        #expect(try await store.additions(since: TestData.date).isEmpty)
    }

    @Test func returnsOnlyAdditionsFromDateOnNewestFirst() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        _ = try await store.record(TestData.snapshot(), events: [
            event(.added, label: "old", at: -1),
            event(.added, label: "boundary", at: 0),
            event(.removed, label: "removed", at: 1),
            event(.modified, label: "modified", at: 2),
            event(.added, label: "new", at: 3),
        ])
        #expect(offsets(try await store.additions(since: TestData.date)) == [3, 0])
    }

    @Test func pagesBeyondOnePage() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        let count = SwiftDataSnapshotStore.additionsPageSize * 2 + 5
        let events = (1...count).map { event(.added, label: "e\($0)", at: TimeInterval($0)) }
            + [event(.added, label: "before", at: -10)]
        _ = try await store.record(TestData.snapshot(), events: events)
        let additions = try await store.additions(since: TestData.date)
        #expect(additions.count == count)
        #expect(Set(additions.map(\.id)).count == count)
        #expect(offsets(additions) == (1...count).reversed().map(TimeInterval.init))
    }
}
