import Darwin
import Synchronization

/// Kurzname eines Benutzers zur UID (`getpwuid_r`), je UID nur einmal gelesen: Der Tab „Details“ fragt in jedem Takt für
/// jeden Prozess, die Benutzerdatenbank (opendirectoryd) wäre dafür zu langsam. Unbekannte UIDs erscheinen als Zahl.
public final class UserNameCache: Sendable {
    public static let shared = UserNameCache()

    private let lookup: @Sendable (UInt32) -> String?
    private let names = Mutex<[UInt32: String]>([:])

    public init(lookup: @escaping @Sendable (UInt32) -> String? = { UserNameCache.systemName($0) }) {
        self.lookup = lookup
    }

    public func name(for uid: UInt32) -> String {
        if let name = names.withLock({ $0[uid] }) { return name }
        let name = lookup(uid) ?? String(uid)
        names.withLock { $0[uid] = name }
        return name
    }

    /// Kurzname aus der Benutzerdatenbank; `nil`, wenn es die UID nicht gibt.
    public static func systemName(_ uid: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        return buffer.withUnsafeMutableBufferPointer { storage in
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(uid, &entry, storage.baseAddress, storage.count, &result) == 0, result != nil,
                  let name = entry.pw_name else { return nil }
            return String(cString: name)
        }
    }
}
