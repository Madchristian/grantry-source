import Foundation
import os

/// Schwelle des Hinweises auf verwaiste Agenten-Bäume (#224): mehr als `treeCount` Bäume oder zusammen mehr als
/// `memoryBytes` Speicher.
public struct OrphanAgentAlertThreshold: Hashable, Sendable {
    /// Mehr als 10 Bäume oder mehr als 2 GB.
    public static let standard = OrphanAgentAlertThreshold(treeCount: 10, memoryBytes: 2 << 30)

    public let treeCount: Int
    public let memoryBytes: UInt64

    public init(treeCount: Int, memoryBytes: UInt64) {
        self.treeCount = treeCount
        self.memoryBytes = memoryBytes
    }

    func isExceeded(by orphans: [AgentProcessTree]) -> Bool {
        orphans.count > treeCount || Self.totalMemory(of: orphans) > memoryBytes
    }

    /// Entspannt: höchstens die Hälfte beider Grenzen, etwa nach dem Aufräumen. Erst danach darf ein weiterer Hinweis
    /// kommen (Hysterese) – eine Lage, die um die Schwelle pendelt, meldet sich so nur einmal.
    func isCleared(by orphans: [AgentProcessTree]) -> Bool {
        orphans.count <= treeCount / 2 && Self.totalMemory(of: orphans) <= memoryBytes / 2
    }

    static func totalMemory(of orphans: [AgentProcessTree]) -> UInt64 {
        orphans.map(\.memoryBytes).reduce(0, +)
    }
}

/// Hinweis auf viele verwaiste Agenten-Bäume (#224): liest alle `interval` nur die Prozesstabelle
/// (`ProcessOverviewScanner.scanAgentTrees()`, ohne `simctl` und Speicherstatus) und meldet einmal, sobald die
/// `OrphanAgentAlertThreshold` überschritten ist. Beendet wird nie etwas; ein Klick auf die Meldung öffnet
/// Aufräumen → Prozesse.
///
/// Entprellung per Hysterese: Nach einem Hinweis kommt der nächste erst, wenn die Lage zwischendurch entspannt war
/// (`OrphanAgentAlertThreshold.isCleared`); der Zustand überdauert Neustarts (`OrphanAgentAlertPreferences.isArmed`).
/// Abgeschaltet entfällt der Scan ganz, und ein späteres Einschalten darf sofort wieder melden.
@MainActor
public final class OrphanAgentAlerter {
    /// Abstand der Prüfungen; die erste folgt einen Abstand nach `start()`, damit der Start der App unbelastet bleibt.
    nonisolated public static let interval: Duration = .seconds(15 * 60)
    /// Eine neue Meldung ersetzt eine noch sichtbare.
    static let notificationIdentifier = "orphanAgentTrees"

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "orphan-agent-alert")

    private let scan: @Sendable () async throws -> AgentTreeScan
    private let notifier: any UserNotifying
    private let preferences: OrphanAgentAlertPreferences
    private let threshold: OrphanAgentAlertThreshold
    private var schedule: Task<Void, Never>?

    public convenience init(
        scanner: ProcessOverviewScanner,
        notifier: any UserNotifying,
        preferences: OrphanAgentAlertPreferences = OrphanAgentAlertPreferences()
    ) {
        self.init(scan: { try await scanner.scanAgentTrees() }, notifier: notifier, preferences: preferences)
    }

    init(
        scan: @escaping @Sendable () async throws -> AgentTreeScan,
        notifier: any UserNotifying,
        preferences: OrphanAgentAlertPreferences,
        threshold: OrphanAgentAlertThreshold = .standard
    ) {
        self.scan = scan
        self.notifier = notifier
        self.preferences = preferences
        self.threshold = threshold
    }

    /// Startet den Prüftakt; weitere Aufrufe bleiben wirkungslos.
    public func start() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.interval) } catch { return }
                await self?.check()
            }
        }
    }

    /// Beendet den Prüftakt; eine laufende Prüfung meldet danach nichts mehr.
    public func stop() {
        schedule?.cancel()
        schedule = nil
    }

    /// Eine Prüfung: meldet beim Überschreiten der Schwelle, wenn der Hinweis fällig werden darf, und gibt ihn wieder
    /// frei, sobald die Lage entspannt ist. Ein unlesbarer Scan ändert nichts.
    func check() async {
        guard preferences.isEnabled else {
            if !preferences.isArmed { preferences.isArmed = true }
            return
        }
        let orphans: [AgentProcessTree]
        do {
            orphans = try await scan().orphans
        } catch {
            Self.logger.notice("Prüfung auf verwaiste Agenten-Bäume gescheitert: \(error.readableDescription, privacy: .public)")
            return
        }
        // Während des Scans abgeschaltet oder beendet: nichts mehr melden.
        guard !Task.isCancelled, preferences.isEnabled else { return }
        if threshold.isExceeded(by: orphans) {
            guard preferences.isArmed else { return }
            preferences.isArmed = false
            await notifier.post(
                title: ProcessCleanupPresentation.alertTitle, body: ProcessCleanupPresentation.alertBody(orphans),
                identifier: Self.notificationIdentifier, destination: .processes
            )
        } else if threshold.isCleared(by: orphans), !preferences.isArmed {
            preferences.isArmed = true
        }
    }
}
