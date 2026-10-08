import Foundation

public enum UpdateCheckError: LocalizedError, Equatable {
    /// Feed nicht erreichbar (offline, Zeitüberschreitung, HTTP-Fehler); Grund als lesbarer Text.
    case unreachable(String)
    /// Feed ist kein gültiges XML oder überschreitet die Grenzen aus `UpdateFeed` (Größe, Einträge, Felder, Tiefe).
    case invalidFeed

    public var errorDescription: String? {
        switch self {
        case .unreachable(let reason): "Keine Verbindung zu \(UpdateFeed.host) (\(reason))."
        case .invalidFeed: "Die Versionsliste von \(UpdateFeed.host) ist ungültig."
        }
    }
}

/// Holt den Feed und wählt die neueste Version, die neuer ist als die laufende und auf diesem macOS läuft.
public struct UpdateChecker: Sendable {
    public let feedURL: URL
    public let installed: InstalledBuild
    private let fetcher: any FeedFetching

    public init(
        feedURL: URL = UpdateFeed.url, fetcher: any FeedFetching = URLSessionFeedFetcher(),
        installed: InstalledBuild = .current()
    ) {
        self.feedURL = feedURL
        self.fetcher = fetcher
        self.installed = installed
    }

    /// Neueste passende Version; `nil`, wenn die laufende aktuell ist.
    public func check() async throws -> AppcastItem? {
        let data: Data
        do {
            data = try await fetcher.fetch(feedURL, userAgent: installed.userAgent)
        } catch where Task.isCancelled || (error as? URLError)?.code == .cancelled {
            // `URLSession` meldet einen Abbruch als `URLError(.cancelled)`, nicht als `CancellationError`.
            throw CancellationError()
        } catch FeedFetchError.tooLarge {
            throw UpdateCheckError.invalidFeed
        } catch {
            throw UpdateCheckError.unreachable(error.readableDescription)
        }
        guard let items = try? AppcastParser.items(from: data) else { throw UpdateCheckError.invalidFeed }
        return items.filter(isApplicable).max { $0.build < $1.build }
    }

    /// Neuer als die laufende Version und lauffähig auf diesem macOS.
    private func isApplicable(_ item: AppcastItem) -> Bool {
        guard item.build > installed.build else { return false }
        return item.minimumSystemVersion.map { $0 <= installed.systemVersion } ?? true
    }
}
