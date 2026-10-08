import Foundation

/// macOS-Version zum Vergleichen, z. B. mit `sparkle:minimumSystemVersion`.
public struct SystemVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// „27“, „27.1“ oder „27.1.2“; sonst `nil`.
    public init?(dotted: String) {
        let parts = dotted.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, (1...3).contains(numbers.count), numbers.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        self.init(
            major: numbers[0], minor: numbers.count > 1 ? numbers[1] : 0, patch: numbers.count > 2 ? numbers[2] : 0
        )
    }

    /// Laufendes macOS.
    public static var current: SystemVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemVersion(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    public static func < (lhs: SystemVersion, rhs: SystemVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}
