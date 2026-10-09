import Foundation
import Synchronization
import Testing
@testable import ManagerKit

@Suite struct UpdateCheckerTests {
    /// Klasse statt Struktur: `Mutex` ist nicht kopierbar.
    private final class FakeFetcher: FeedFetching {
        let result: Result<Data, any Error>
        let requests = Mutex<[(URL, String)]>([])

        init(result: Result<Data, any Error>) {
            self.result = result
        }

        func fetch(_ url: URL, userAgent: String) async throws -> Data {
            requests.withLock { $0.append((url, userAgent)) }
            return try result.get()
        }
    }

    private struct Offline: Error {}

    private static let installed = InstalledBuild(
        info: ["CFBundleShortVersionString": "2026.10.4", "CFBundleVersion": "276"],
        systemVersion: SystemVersion(major: 27), architecture: "arm64"
    )

    private func checker(_ result: Result<Data, any Error>) -> (UpdateChecker, FakeFetcher) {
        let fetcher = FakeFetcher(result: result)
        return (UpdateChecker(feedURL: UpdateFeed.url, fetcher: fetcher, installed: Self.installed), fetcher)
    }

    @Test func picksTheHighestNewerBuild() async throws {
        let (checker, fetcher) = checker(.success(AppcastParserTests.feed(
            AppcastParserTests.item(version: "2026.10.5", build: "280"),
            AppcastParserTests.item(version: "2026.10.6", build: "290"),
            AppcastParserTests.item(version: "2026.10.4", build: "276")
        )))
        #expect(try await checker.check()?.build == 290)
        let request = try #require(fetcher.requests.withLock { $0.first })
        #expect(request.0 == UpdateFeed.url)
        #expect(request.1 == "Grantry/2026.10.4 (276; macOS 27.0; arm64)")
    }

    @Test func skipsImplausibleBuildJumpsButAcceptsTheBoundary() async throws {
        let (checker, _) = checker(.success(AppcastParserTests.feed(
            AppcastParserTests.item(build: "100277"),
            AppcastParserTests.item(build: "100276"),
            AppcastParserTests.item(build: "280")
        )))
        #expect(try await checker.check()?.build == 100_276)
    }

    @Test func ignoresAFeedContainingOnlyAnImplausibleBuildJump() async throws {
        let (checker, _) = checker(.success(AppcastParserTests.feed(AppcastParserTests.item(build: "100277"))))
        #expect(try await checker.check() == nil)
    }

    @Test(arguments: [Int.min, Int.max])
    func extremeInstalledBuildDoesNotOverflow(build: Int) async throws {
        let installed = InstalledBuild(info: ["CFBundleVersion": String(build)],
                                       systemVersion: SystemVersion(major: 27), architecture: "arm64")
        let checker = UpdateChecker(fetcher: FakeFetcher(result: .success(
            AppcastParserTests.feed(AppcastParserTests.item())
        )), installed: installed)
        #expect(try await checker.check() == nil)
    }

    @Test func nothingNewerMeansUpToDate() async throws {
        let (checker, _) = checker(.success(
            AppcastParserTests.feed(AppcastParserTests.item(version: "2026.10.4", build: "276"))
        ))
        #expect(try await checker.check() == nil)
    }

    @Test func skipsVersionsForANewerMacOS() async throws {
        let (checker, _) = checker(.success(AppcastParserTests.feed(
            AppcastParserTests.item(version: "2026.11.1", build: "300", minimumSystem: "28.0"),
            AppcastParserTests.item(version: "2026.10.5", build: "280", minimumSystem: "27.0")
        )))
        #expect(try await checker.check()?.build == 280)
    }

    @Test func fetchFailureIsUnreachable() async {
        let (checker, _) = checker(.failure(Offline()))
        let error = await #expect(throws: UpdateCheckError.self) { try await checker.check() }
        guard case .unreachable? = error else {
            Issue.record("erwartet .unreachable, erhalten \(String(describing: error))")
            return
        }
    }

    @Test func urlSessionCancellationStaysACancellation() async {
        let (checker, _) = checker(.failure(URLError(.cancelled)))
        await #expect(throws: CancellationError.self) { try await checker.check() }
    }

    @Test func malformedFeedIsInvalid() async {
        let (checker, _) = checker(.success(Data("kein xml <".utf8)))
        await #expect(throws: UpdateCheckError.invalidFeed) { try await checker.check() }
    }

    @Test func oversizedFeedIsInvalidNotUnreachable() async {
        // Der Server antwortet ja; nur der Inhalt ist unbrauchbar.
        let (checker, _) = checker(.failure(FeedFetchError.tooLarge))
        await #expect(throws: UpdateCheckError.invalidFeed) { try await checker.check() }
    }

    @Test func feedBeyondTheItemLimitStillYieldsTheNewestVersion() async throws {
        // Der Feed führt die neueste Version oben; Einträge hinter der Grenze werden ignoriert, der Feed bleibt gültig.
        let newest = AppcastParserTests.item(version: "2026.10.6", build: "290")
        let older = (1...UpdateFeed.maximumItems).map { AppcastParserTests.item(version: "2026.1.\($0)", build: "\($0)") }
        let (checker, _) = checker(.success(AppcastParserTests.feed(items: [newest] + older)))
        #expect(try await checker.check()?.build == 290)
    }
}
