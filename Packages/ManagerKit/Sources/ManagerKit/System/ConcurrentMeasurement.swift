/// Misst Größen begrenzt parallel (DRY für Reste-Suche und Speicher-Kategorien).
enum ConcurrentMeasurement {
    /// Ergebnis einer Messung in der Task-Gruppe (Struct statt Tupel mit Enum).
    private struct Measured<Value: Sendable>: Sendable {
        let index: Int
        let value: Value
    }

    /// Größen in der Reihenfolge von `paths` mit höchstens `maximumConcurrent` gleichzeitigen Messungen; nach einem
    /// Abbruch startet keine weitere, ungemessene bleiben `.unknown`. `sizer` wählt das Messwerkzeug je Index.
    static func sizes(
        of paths: [String], maximumConcurrent: Int = LeftoverScanner.maximumConcurrentMeasurements,
        sizer: (Int) -> any FileSizeMeasuring
    ) async -> [FileSize] {
        await results(of: paths, maximumConcurrent: maximumConcurrent, unmeasured: .unknown) { index in
            let sizer = sizer(index)
            return { await sizer.measure($0) }
        }
    }

    /// Wie `sizes(of:maximumConcurrent:sizer:)` mit einem Messwerkzeug für alle Pfade.
    static func sizes(of paths: [String], measurer: any FileSizeMeasuring) async -> [FileSize] {
        await sizes(of: paths) { _ in measurer }
    }

    /// Größe und jüngste Änderung je Pfad (#229), begrenzt parallel wie `sizes`.
    static func summaries(of paths: [String], measurer: any FileSizeMeasuring) async -> [FileTreeSummary] {
        await results(of: paths, maximumConcurrent: LeftoverScanner.maximumConcurrentMeasurements, unmeasured: .unmeasured) { _ in
            { await measurer.summarize($0) }
        }
    }

    private static func results<Value: Sendable>(
        of paths: [String], maximumConcurrent: Int, unmeasured: Value,
        measurement: (Int) -> @Sendable (String) async -> Value
    ) async -> [Value] {
        var results = [Value](repeating: unmeasured, count: paths.count)
        await withTaskGroup(of: Measured<Value>.self) { group in
            var next = 0
            func startNext() {
                guard next < paths.count else { return }
                let index = next, path = paths[index], measure = measurement(index)
                next += 1
                _ = group.addTaskUnlessCancelled {
                    Measured(index: index, value: Task.isCancelled ? unmeasured : await measure(path))
                }
            }
            for _ in 0..<max(1, maximumConcurrent) { startNext() }
            for await measured in group {
                results[measured.index] = measured.value
                startNext()
            }
        }
        return results
    }
}
