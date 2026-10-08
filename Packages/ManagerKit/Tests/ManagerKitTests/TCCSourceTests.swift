import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@Suite struct TCCSourceTests {
    /// Legt eine Datenbank im aktuellen Schema mit den Zeilen `inserts` an und übergibt ihren Pfad an `body`.
    private func withDatabase<T>(_ inserts: [String], _ body: (String) async throws -> T) async throws -> T {
        try await SQLiteFixture.withDatabase([SQLiteFixture.currentAccessSchema] + inserts, body)
    }

    private func source(path: String, scope: TCCScope = .user, resolver: any AppResolving = StubAppResolver()) -> TCCSource {
        TCCSource(database: TCCDatabaseLocation(path: path, scope: scope), resolver: resolver)
    }

    @Test func readsSingleDatabaseAndDerivesSourceFromScope() async throws {
        let userRows = [SQLiteFixture.insert(service: "kTCCServiceCamera", client: "us.zoom.xos", lastModified: 100)]
        let (source, contribution) = try await withDatabase(userRows) { path in
            let source = source(path: path, scope: .user)
            return (source, try await source.collect())
        }

        #expect(source.id == .tccUser)
        #expect(contribution.autostartItems.isEmpty)
        #expect(contribution.grants.map(\.id) == ["user|kTCCServiceCamera|us.zoom.xos"])
        #expect(contribution.grants.map(\.authValue) == [.allowed])
        #expect(contribution.grants.map(\.source) == [.tccUser])
        #expect(contribution.grants.map(\.lastModified) == [Date(timeIntervalSince1970: 100)])
        #expect(contribution.grants[0].client.bundleID == "us.zoom.xos")
    }

    @Test func systemDatabaseYieldsSystemScopedGrants() async throws {
        let systemRows = [SQLiteFixture.insert(
            service: "kTCCServiceScreenCapture", client: "/opt/tool", clientType: 1, authValue: 0, lastModified: 200
        )]
        let (source, contribution) = try await withDatabase(systemRows) { path in
            let source = source(path: path, scope: .system)
            return (source, try await source.collect())
        }

        #expect(source.id == .tccSystem)
        #expect(contribution.grants.map(\.id) == ["system|kTCCServiceScreenCapture|/opt/tool"])
        #expect(contribution.grants.map(\.authValue) == [.denied])
        #expect(contribution.grants.map(\.source) == [.tccSystem])
        #expect(contribution.grants[0].client.bundleID == nil)
        #expect(contribution.grants[0].client.path == "/opt/tool")
    }

    @Test func standardDefaultsToSystemDatabaseOnly() {
        let sources = TCCSource.standard(resolver: StubAppResolver())
        #expect(sources.map(\.id) == [.tccSystem])
        let tccSources = sources.compactMap { $0 as? TCCSource }
        #expect(tccSources.map(\.database) == [.system])
    }

    @Test func standardIncludesUserDatabaseWhenRequested() {
        let sources = TCCSource.standard(resolver: StubAppResolver(), includeUserDatabase: true)
        #expect(sources.map(\.id) == [.tccUser, .tccSystem])
        let tccSources = sources.compactMap { $0 as? TCCSource }
        #expect(tccSources.map(\.database) == [.user, .system])
    }

    @Test func automationTargetsYieldDistinctGrantsKeyedByRawClient() async throws {
        let rows = ["com.apple.finder", "com.apple.systemevents"].map {
            SQLiteFixture.insert(service: "kTCCServiceAppleEvents", client: "com.example.tool", indirectObject: $0)
        }
        let resolver = RenamingResolver()

        let contribution = try await withDatabase(rows) { path in
            try await source(path: path, resolver: resolver).collect()
        }

        #expect(contribution.grants.map(\.id) == [
            "user|kTCCServiceAppleEvents|com.example.tool|com.apple.finder",
            "user|kTCCServiceAppleEvents|com.example.tool|com.apple.systemevents",
        ])
        #expect(contribution.grants.map(\.target) == ["com.apple.finder", "com.apple.systemevents"])
        #expect(contribution.grants.allSatisfy { $0.client.bundleID == "resolved.com.example.tool" })
        #expect(resolver.calls == 1)
    }

    @Test func unreadableDatabaseFailsSource() async {
        let source = source(path: "/nonexistent/TCC.db")
        await #expect(throws: TCCReadError.self) { try await source.collect() }
    }

    /// Ein bereits abgebrochener Task liest die Datenbank gar nicht erst: Ein nicht existierender Pfad würde sonst
    /// `TCCReadError` statt `CancellationError` werfen. Der Abbruch geschieht innerhalb des Tasks selbst, vor dem
    /// Aufruf von `collect()` – ohne Wettlauf mit dessen Start.
    @Test func checksCancellationBeforeReading() async throws {
        let source = source(path: "/nonexistent/TCC.db")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.collect()
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    /// Eine unlesbare Benutzer-Datenbank (macOS 27) darf die lesbaren System-Grants nicht verschlucken.
    @Test func unreadableUserDatabaseKeepsSystemGrants() async throws {
        let systemRows = [SQLiteFixture.insert(service: "kTCCServiceScreenCapture", client: "com.example.tool")]
        let snapshot = try await withDatabase(systemRows) { system in
            try await ScanCoordinator(sources: [
                source(path: "/nonexistent/TCC.db", scope: .user),
                source(path: system, scope: .system),
            ], now: { TestData.date }).scan()
        }

        #expect(snapshot.grants.map(\.id) == ["system|kTCCServiceScreenCapture|com.example.tool"])
        #expect(snapshot.failedSources == [.tccUser])
    }
}

/// Liefert eine vom Rohwert abweichende Identität und zählt die Auflösungen.
private final class RenamingResolver: AppResolving {
    private let count = Mutex(0)

    var calls: Int { count.withLock { $0 } }

    func resolve(bundleID: String) async -> AppIdentity {
        count.withLock { $0 += 1 }
        return TestData.app("resolved.\(bundleID)")
    }

    func resolve(path: String) async -> AppIdentity {
        count.withLock { $0 += 1 }
        return TestData.app("resolved.\(path)")
    }
}
