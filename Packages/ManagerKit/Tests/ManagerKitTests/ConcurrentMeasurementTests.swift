import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@Suite struct ConcurrentMeasurementTests {
    /// Zählt gleichzeitige Messungen und merkt sich das Maximum; Größe = Länge des Pfads.
    private final class CountingMeasurer: FileSizeMeasuring {
        private let state = Mutex((running: 0, peak: 0))

        var peak: Int { state.withLock { $0.peak } }

        func allocatedSize(of path: String) -> Int64? { Int64(path.count) }

        func measure(_ path: String) async -> FileSize {
            state.withLock {
                $0.running += 1
                $0.peak = max($0.peak, $0.running)
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 1...10)))
            state.withLock { $0.running -= 1 }
            return .bytes(Int64(path.count))
        }
    }

    @Test func sizesKeepInputOrderAndRespectLimit() async {
        let measurer = CountingMeasurer()
        let paths = (1...12).map { String(repeating: "x", count: $0) }
        let sizes = await ConcurrentMeasurement.sizes(of: paths, maximumConcurrent: 2) { _ in measurer }
        #expect(sizes == paths.map { .bytes(Int64($0.count)) })
        #expect(measurer.peak <= 2)
    }

    @Test func cancelledMeasurementIsUnknown() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ConcurrentMeasurement.sizes(of: ["a", "b"], measurer: CountingMeasurer())
        }
        #expect(await task.value == [.unknown, .unknown])
    }
}
