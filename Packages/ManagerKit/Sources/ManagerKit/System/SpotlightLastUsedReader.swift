import CoreServices
import Foundation

/// „Zuletzt benutzt“ eines Bundles.
public protocol LastUsedReading: Sendable {
    /// `nil`: unbekannt (Spotlight aus, nie benutzt, Zeitüberschreitung).
    func lastUsed(ofBundleAt path: String) -> Date?
}

/// Über Spotlight (`kMDItemLastUsedDate`), mit Zeitgrenze (`BlockingCallGuard.spotlight`).
public struct SpotlightLastUsedReader: LastUsedReading {
    public static let timeout: Duration = .seconds(2)

    public init() {}

    public func lastUsed(ofBundleAt path: String) -> Date? {
        BlockingCallGuard.spotlight.run(timeout: Self.timeout) {
            guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
            return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        } ?? nil
    }
}
