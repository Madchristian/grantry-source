import Foundation

/// Versionierte, begrenzte Ablage. Fehler/alte Formate sind Cache-Misses; nie ein Sicherheitsurteil.
struct DeepSignatureCache: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let fingerprint: String
        let verdict: DeepSignatureVerdict
    }

    static let maximumEntries = 2_048

    var version = 1
    var entries: [String: Entry] = [:]

    /// Nicht beurteilbar kann ein transienter Security-/Berechtigungsfehler sein: nur im Prozess merken.
    private var persistable: Self {
        Self(entries: entries.filter { $0.value.verdict != .unverifiable })
    }

    static func load(from url: URL?) -> Self {
        guard let url,
              let data = FileType.contentsOfRegularFile(atPath: url.path, maximumLength: 8 * 1_024 * 1_024),
              let cache = try? JSONDecoder().decode(Self.self, from: data), cache.version == 1,
              cache.entries.count <= maximumEntries else { return Self() }
        return cache.persistable
    }

    func save(to url: URL?) {
        guard let url, entries.count <= Self.maximumEntries, let data = try? JSONEncoder().encode(persistable) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { /* Opportunistischer Cache: beim nächsten Aufruf vollständig neu prüfen. */ }
    }
}
