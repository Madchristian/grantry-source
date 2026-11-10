import Darwin
import Foundation
import Testing
@testable import ManagerKit

@Suite struct UserNameCacheTests {
    @Test func looksUpEachUIDOnlyOnce() {
        let calls = Recorder<UInt32>()
        let cache = UserNameCache { uid in
            calls.append(uid)
            return uid == 0 ? "root" : nil
        }
        #expect(cache.name(for: 0) == "root")
        #expect(cache.name(for: 0) == "root")
        #expect(cache.name(for: 4_242) == "4242")
        #expect(cache.name(for: 4_242) == "4242")
        #expect(calls.values == [0, 4_242])
    }

    /// Integration (nur lesend): eigener Benutzer und root aus der echten Benutzerdatenbank.
    @Test func systemNamesResolveCurrentUserAndRoot() {
        #expect(UserNameCache.systemName(getuid()) == NSUserName())
        #expect(UserNameCache.systemName(0) == "root")
        #expect(UserNameCache.systemName(4_000_000_000) == nil)
    }
}
