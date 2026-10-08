import Foundation

/// Lädt den Update-Feed; für Tests austauschbar.
public protocol FeedFetching: Sendable {
    func fetch(_ url: URL, userAgent: String) async throws -> Data
}

public enum FeedFetchError: LocalizedError, Equatable {
    case httpStatus(Int)
    /// Die Antwort ist größer als `UpdateFeed.maximumFeedBytes`.
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "Der Server antwortete mit Status \(code)."
        case .tooLarge: "Die Antwort des Servers ist größer als erlaubt."
        }
    }
}

/// `FeedFetching` über eine flüchtige `URLSession`: keine Cookies, kein Cache, Gesamtfrist 15 s (nicht nur Leerlauf),
/// als eigene Header nur der User-Agent und ein neutrales `Accept-Language: *`. Ohne Letzteres hängt `URLSession`
/// automatisch die bevorzugten Sprachen des Nutzers an (z. B. `de-DE`) – mehr, als `UpdateFeed.privacyNote` verspricht.
/// Datei-URLs (Testfeed in Debug-Builds) werden ebenfalls gelesen.
///
/// Die Antwort wird gestreamt und nie größer als `UpdateFeed.maximumFeedBytes`: Kündigt der Server mehr an, bricht der
/// Abruf ab, bevor ein Byte gelesen ist; sonst zählt er die tatsächlich empfangenen (entpackten) Bytes mit und bricht
/// beim ersten Byte darüber ab (`FeedFetchError.tooLarge`). Ein Server, der die Länge verschweigt oder falsch angibt,
/// kann also keinen Speicher fluten.
public struct URLSessionFeedFetcher: FeedFetching {
    private let protocolClasses: [AnyClass]

    public init() {
        self.init(protocolClasses: [])
    }

    /// Für Tests: `URLProtocol`-Klassen, die die Anfragen statt des Netzes beantworten.
    init(protocolClasses: [AnyClass]) {
        self.protocolClasses = protocolClasses
    }

    public func fetch(_ url: URL, userAgent: String) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept-Language": "*"]
        configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        let session = URLSession(configuration: configuration)
        // Bricht auch eine noch laufende Übertragung ab, wenn das Limit greift.
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedFetchError.httpStatus(http.statusCode)
        }
        // -1: unbekannt (z. B. „chunked“); dann zählt allein, was tatsächlich ankommt.
        let limit = UpdateFeed.maximumFeedBytes
        guard response.expectedContentLength <= limit else { throw FeedFetchError.tooLarge }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 0)
        for try await byte in bytes {
            guard data.count < limit else { throw FeedFetchError.tooLarge }
            data.append(byte)
        }
        return data
    }
}
