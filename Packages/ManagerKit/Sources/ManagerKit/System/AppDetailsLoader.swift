import Foundation

/// Nachgeladene, nicht signifikante Angaben zu einer App (Spec v3 §2).
public struct AppUsageDetails: Hashable, Sendable {
    public var size: Int64?
    public var lastUsed: Date?

    public init(size: Int64? = nil, lastUsed: Date? = nil) {
        self.size = size
        self.lastUsed = lastUsed
    }
}

/// Größe und „zuletzt benutzt“ installierter Apps im Hintergrund.
///
/// Größen: eine Berechnung zur Zeit auf eigener serieller Queue (nie im kooperativen Pool, nie auf dem Main Actor),
/// gemerkt je Pfad und `FileFingerprint` – ein Update rechnet neu, eine Zeitüberschreitung wird nicht gemerkt.
/// „Zuletzt benutzt“ fragt Spotlight bei jedem Aufruf (Millisekunden, mit Zeitgrenze) auf einer zweiten Queue – nie
/// hinter einer langen Größenberechnung (Review N1). Gleichzeitige Anfragen für denselben Pfad teilen sich einen
/// Ladevorgang; ein bereits abgebrochener Aufrufer reiht nichts ein. Symlink-Bundles (`InstalledApp.symlinkTarget`)
/// werden nicht verfolgt und haben keine Angaben.
public actor AppDetailsLoader {
    private let sizes: any FileSizeMeasuring
    private let lastUsed: any LastUsedReading
    private let sizeQueue = DispatchQueue(label: "de.cstrube.Grantry.app-details.size", qos: .utility)
    private let spotlightQueue = DispatchQueue(label: "de.cstrube.Grantry.app-details.spotlight", qos: .utility)
    private var sizeCache = FingerprintCache<Int64>()
    private var loading: [String: Task<AppUsageDetails, Never>] = [:]

    public init(sizes: any FileSizeMeasuring = FileSizeCalculator(), lastUsed: any LastUsedReading = SpotlightLastUsedReader()) {
        self.sizes = sizes
        self.lastUsed = lastUsed
    }

    /// Bereits bekannte Größen, deren Bundle sich nicht verändert hat – ohne zu rechnen.
    public func cachedSizes(for paths: [String]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for path in paths {
            guard let fingerprint = FileFingerprint(of: FileFingerprint.target(of: path)),
                  let size = sizeCache.value(for: path, matching: fingerprint) else { continue }
            result[path] = size
        }
        return result
    }

    public func details(for path: String) async -> AppUsageDetails {
        if let running = loading[path] { return await running.value }
        guard !Task.isCancelled else { return AppUsageDetails() }
        let task = Task { await load(path) }
        loading[path] = task
        let details = await task.value
        if loading[path] == task { loading[path] = nil }
        return details
    }

    private func load(_ path: String) async -> AppUsageDetails {
        guard FileType.linkStatus(of: path).map(FileType.isSymbolicLink) == false else { return AppUsageDetails() }
        let reader = lastUsed
        async let used = Self.run(on: spotlightQueue) { reader.lastUsed(ofBundleAt: path) }
        let size = await size(of: path)
        return AppUsageDetails(size: size, lastUsed: await used)
    }

    private func size(of path: String) async -> Int64? {
        guard let fingerprint = FileFingerprint(of: path) else { return nil }
        if let cached = sizeCache.value(for: path, matching: fingerprint) { return cached }
        let sizes = sizes
        let size = await Self.run(on: sizeQueue) { sizes.allocatedSize(of: path) }
        if let size { sizeCache.store(size, for: path, fingerprint: fingerprint) }
        return size
    }

    private static func run<T: Sendable>(on queue: DispatchQueue, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}
