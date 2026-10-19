import Foundation

/// Lässt die Provider begrenzt parallel scannen und liefert jedes Ergebnis, sobald es vorliegt (Spec Speicher §2.1).
/// Beendet der Verbraucher die Schleife oder wird sein Task abgebrochen, werden die laufenden Scans abgebrochen und
/// keine weiteren gestartet.
public struct StorageScanner: Sendable {
    public static let defaultMaximumConcurrency = 3

    let providers: [any StorageCategoryProvider]
    let maximumConcurrency: Int

    /// `maximumConcurrency` unter 1 wird auf 1 angehoben, damit der Scan nie ohne Ergebnis endet.
    public init(providers: [any StorageCategoryProvider], maximumConcurrency: Int = defaultMaximumConcurrency) {
        self.providers = providers
        self.maximumConcurrency = max(1, maximumConcurrency)
    }

    public func scan() -> AsyncStream<StorageCategoryReport> {
        let providers = providers, limit = maximumConcurrency
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: StorageCategoryReport.self) { group in
                    var pending = providers.makeIterator()
                    for _ in 0..<limit {
                        guard let provider = pending.next() else { break }
                        group.addTask { await provider.scan() }
                    }
                    while let report = await group.next() {
                        // Nach dem Abbruch nichts mehr liefern und nichts nachrücken lassen.
                        guard !Task.isCancelled else { break }
                        continuation.yield(report)
                        if let provider = pending.next() { group.addTask { await provider.scan() } }
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            // Greift auch beim `break` des Verbrauchers: Der Iterator wird freigegeben und beendet den Stream.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
