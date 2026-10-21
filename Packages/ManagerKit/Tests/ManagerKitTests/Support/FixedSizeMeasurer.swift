import Foundation
@testable import ManagerKit

/// Liefert feste Größen je Pfad (Vorgabe `otherwise`, sonst `.unknown`).
final class FixedSizeMeasurer: FileSizeMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [String: FileSize]
    private let otherwise: FileSize

    init(_ sizes: [String: FileSize] = [:], otherwise: FileSize = .unknown) {
        self.sizes = sizes
        self.otherwise = otherwise
    }

    func set(_ size: FileSize, for path: String) {
        lock.withLock { sizes[path] = size }
    }

    func allocatedSize(of path: String) -> Int64? { lock.withLock { sizes[path]?.bytes } }

    func measure(_ path: String) async -> FileSize { lock.withLock { sizes[path] ?? otherwise } }
}
