import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Prüft den echten `URLSessionFeedFetcher` gegen eine `URLProtocol`-Attrappe: kein Netz, aber die Anfrage
/// läuft durch dieselbe Session-Konfiguration wie im Betrieb.
@Suite(.serialized) struct URLSessionFeedFetcherTests {
    private struct Recorded {
        var status = 200
        var body = Data()
        var responseHeaders: [String: String] = [:]
        var headers: [[String: String]] = []
    }

    /// Beantwortet jede Anfrage selbst und merkt sich die gesendeten Header.
    private final class StubProtocol: URLProtocol {
        static let state = Mutex(Recorded())

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let (status, body, responseHeaders) = Self.state.withLock { state in
                state.headers.append(request.allHTTPHeaderFields ?? [:])
                return (state.status, state.body, state.responseHeaders)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: responseHeaders
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // In Stücken wie von einem echten Server, nicht als ein Block.
            for start in stride(from: 0, to: body.count, by: 65_536) {
                client?.urlProtocol(self, didLoad: body.subdata(in: start..<min(start + 65_536, body.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static let userAgent = "Grantry/2026.10.4 (276; macOS 27.0; arm64)"

    private func fetch(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) async throws -> Data {
        StubProtocol.state.withLock { $0 = Recorded(status: status, body: body, responseHeaders: headers) }
        return try await URLSessionFeedFetcher(protocolClasses: [StubProtocol.self])
            .fetch(UpdateFeed.url, userAgent: Self.userAgent)
    }

    private var sentHeaders: [[String: String]] { StubProtocol.state.withLock { $0.headers } }

    @Test func sendsUserAgentAndNeutralLanguageOnly() async throws {
        _ = try await fetch()
        let headers = try #require(sentHeaders.first)
        #expect(headers["User-Agent"] == Self.userAgent)
        // Ohne eigenen Wert schickt URLSession die bevorzugten Sprachen des Nutzers (z. B. „de-DE“) mit.
        #expect(headers["Accept-Language"] == "*")
        #expect(headers["Cookie"] == nil)
    }

    @Test func returnsTheBodyOnStatus200() async throws {
        let body = Data("<rss/>".utf8)
        #expect(try await fetch(body: body) == body)
    }

    @Test func throwsTheStatusForEverythingButOK() async throws {
        await #expect(throws: FeedFetchError.httpStatus(404)) { try await fetch(status: 404) }
    }

    // MARK: Größenlimit (#103)

    @Test func acceptsABodyExactlyAtTheLimit() async throws {
        let body = Data(repeating: UInt8(ascii: "a"), count: UpdateFeed.maximumFeedBytes)
        #expect(try await fetch(body: body) == body)
    }

    @Test func rejectsABodyAboveTheLimitEvenWithoutAContentLength() async {
        // Ohne `Content-Length` (wie bei „chunked“) bleibt nur das Mitzählen der empfangenen Bytes.
        let body = Data(repeating: UInt8(ascii: "a"), count: UpdateFeed.maximumFeedBytes + 1)
        await #expect(throws: FeedFetchError.tooLarge) { try await fetch(body: body) }
    }

    @Test func rejectsADeclaredLengthAboveTheLimitBeforeReading() async {
        // Der Body selbst ist klein: ohne Vorabprüfung der angekündigten Länge käme er unbeanstandet zurück.
        let declared = ["Content-Length": "\(UpdateFeed.maximumFeedBytes + 1)"]
        await #expect(throws: FeedFetchError.tooLarge) {
            try await fetch(body: Data("<rss/>".utf8), headers: declared)
        }
    }

    @Test func acceptsADeclaredLengthAtTheLimit() async throws {
        let body = Data("<rss/>".utf8)
        let declared = ["Content-Length": "\(UpdateFeed.maximumFeedBytes)"]
        #expect(try await fetch(body: body, headers: declared) == body)
    }

    @Test func reportsTheStatusInsteadOfTheSizeOfAnErrorPage() async {
        let body = Data(repeating: UInt8(ascii: "a"), count: UpdateFeed.maximumFeedBytes + 1)
        await #expect(throws: FeedFetchError.httpStatus(503)) { try await fetch(status: 503, body: body) }
    }

    // MARK: Datei-URLs (Testfeed in Debug-Builds)

    /// Legt eine Datei an und führt `body` mit deren URL aus; kein Netz, kein `URLProtocol`.
    private func withTemporaryFile<T>(_ contents: Data, _ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory.appending(path: "grantry-feed-\(UUID().uuidString).xml")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    @Test func readsAFileURL() async throws {
        let contents = Data("<rss/>".utf8)
        let read = try await withTemporaryFile(contents) { url in
            try await URLSessionFeedFetcher().fetch(url, userAgent: Self.userAgent)
        }
        #expect(read == contents)
    }

    @Test func rejectsAnOversizedFile() async throws {
        let contents = Data(repeating: UInt8(ascii: "a"), count: UpdateFeed.maximumFeedBytes + 1)
        _ = try await withTemporaryFile(contents) { url in
            await #expect(throws: FeedFetchError.tooLarge) {
                try await URLSessionFeedFetcher().fetch(url, userAgent: Self.userAgent)
            }
        }
    }
}
