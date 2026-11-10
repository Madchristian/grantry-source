/// Hält das letzte Belegungsergebnis – nur im Speicher – und verwirft es 10 min, nachdem die Ansicht verdeckt wurde
/// (Spec 2026-11-08 § 4.4). Der Ablauf ist ein einzelner Schlaf, der nur bei verdeckter Ansicht läuft; kein Takt.
/// Erneute Scans derselben Wurzel bauen auf dem gehaltenen Ergebnis auf.
public actor OccupancyStore {
    public static let retention: Duration = .seconds(600)

    private let scanner: OccupancyScanner
    private let clock: any Clock<Duration>
    private let retention: Duration

    /// Das letzte Ergebnis, bis es abläuft oder verworfen wird.
    public private(set) var tree: OccupancyTree?
    public private(set) var isScanning = false
    private var isVisible = false
    private var expiry: Task<Void, Never>?
    /// Zählt Planungen des Ablaufs: Ein überholter Ablauf verwirft nichts.
    private var expiryGeneration = 0

    public init(
        scanner: OccupancyScanner = OccupancyScanner(), clock: any Clock<Duration> = ContinuousClock(),
        retention: Duration = OccupancyStore.retention
    ) {
        self.scanner = scanner
        self.clock = clock
        self.retention = retention
    }

    /// Scannt `path` und behält das Ergebnis; ein Abbruch behält das vorige. `excluding` ersetzt die Ausnahmen des
    /// Scanners für diesen Scan (etwa die geschützten Orte, solange der Festplattenvollzugriff fehlt).
    /// - Throws: `OccupancyScanError.busy`, solange ein anderer Scan läuft; sonst wie `OccupancyScanner.scan`.
    public func scan(
        _ path: String, excluding excluded: Set<String>? = nil,
        progress: @escaping @Sendable (OccupancyProgress) -> Void = { _ in }
    ) async throws -> OccupancyTree {
        guard !isScanning else { throw OccupancyScanError.busy }
        isScanning = true
        defer {
            isScanning = false
            scheduleExpiryIfHidden()
        }
        let scanner = excluded.map(scanner.excluding) ?? scanner
        let result = try await scanner.scan(path, reusing: tree, progress: progress)
        tree = result
        return result
    }

    /// Meldet, ob die Ansicht zu sehen ist; verdeckt beginnt die Frist bis zum Verwerfen.
    public func setVisible(_ isVisible: Bool) {
        self.isVisible = isVisible
        cancelExpiry()
        scheduleExpiryIfHidden()
    }

    public func discard() {
        cancelExpiry()
        tree = nil
    }

    private func cancelExpiry() {
        expiry?.cancel()
        expiry = nil
        expiryGeneration += 1
    }

    private func scheduleExpiryIfHidden() {
        guard !isVisible, tree != nil, expiry == nil else { return }
        let clock = clock, retention = retention, generation = expiryGeneration
        expiry = Task { [weak self] in
            do { try await clock.sleep(for: retention) } catch { return }
            await self?.expire(generation)
        }
    }

    private func expire(_ generation: Int) {
        guard generation == expiryGeneration, !isVisible else { return }
        expiry = nil
        tree = nil
    }
}
