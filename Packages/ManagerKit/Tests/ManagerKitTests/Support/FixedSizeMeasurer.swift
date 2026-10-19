import Foundation
@testable import ManagerKit

/// Liefert feste Größen je Pfad (Vorgabe `.unknown`).
final class FixedSizeMeasurer: FileSizeMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [String: FileSize]

    init(_ sizes: [String: FileSize] = [:]) {
        self.sizes = sizes
    }

    func set(_ size: FileSize, for path: String) {
        lock.withLock { sizes[path] = size }
    }

    func allocatedSize(of path: String) -> Int64? { lock.withLock { sizes[path]?.bytes } }

    func measure(_ path: String) async -> FileSize { lock.withLock { sizes[path] ?? .unknown } }
}
