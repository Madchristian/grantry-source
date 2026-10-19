/// Misst Größen begrenzt parallel (DRY für Reste-Suche und Speicher-Kategorien).
enum ConcurrentMeasurement {
    /// Ergebnis einer Messung in der Task-Gruppe (Struct statt Tupel mit Enum).
    private struct MeasuredSize: Sendable {
        let index: Int
        let size: FileSize
    }

    /// Größen in der Reihenfolge von `paths` mit höchstens `maximumConcurrent` gleichzeitigen Messungen; nach einem
    /// Abbruch startet keine weitere, ungemessene bleiben `.unknown`. `sizer` wählt das Messwerkzeug je Index.
    static func sizes(
        of paths: [String], maximumConcurrent: Int = LeftoverScanner.maximumConcurrentMeasurements,
        sizer: (Int) -> any FileSizeMeasuring
    ) async -> [FileSize] {
        var results = [FileSize](repeating: .unknown, count: paths.count)
        await withTaskGroup(of: MeasuredSize.self) { group in
            var next = 0
            func startNext() {
                guard next < paths.count else { return }
                let index = next, path = paths[index], sizer = sizer(index)
                next += 1
                _ = group.addTaskUnlessCancelled {
                    MeasuredSize(index: index, size: Task.isCancelled ? .unknown : await sizer.measure(path))
                }
            }
            for _ in 0..<max(1, maximumConcurrent) { startNext() }
            for await measurement in group {
                results[measurement.index] = measurement.size
                startNext()
            }
        }
        return results
    }

    /// Wie `sizes(of:maximumConcurrent:sizer:)` mit einem Messwerkzeug für alle Pfade.
    static func sizes(of paths: [String], measurer: any FileSizeMeasuring) async -> [FileSize] {
        await sizes(of: paths) { _ in measurer }
    }
}
