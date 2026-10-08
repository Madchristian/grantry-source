import Foundation

/// Eingaben der Anzeige-Daten: was `PresentationSnapshot.make` aus dem Monitoring-Zustand braucht.
public struct PresentationInput: Equatable, Sendable {
    public let snapshot: Snapshot
    public let findings: [RiskFinding]
    /// Die jüngsten Events (`MonitoringState.recentEvents`).
    public let events: [HistoryEvent]
    /// `.added`-Events seit `RecordBadges.newItemInterval`.
    public let recentAdditions: [HistoryEvent]
    /// Quellen, die ein Vollscan fragt (`MonitoringState.activeSources`); `nil`: alle.
    public let activeSources: Set<SourceID>?

    public init(
        snapshot: Snapshot, findings: [RiskFinding], events: [HistoryEvent], recentAdditions: [HistoryEvent],
        activeSources: Set<SourceID>? = nil
    ) {
        self.snapshot = snapshot
        self.findings = findings
        self.events = events
        self.recentAdditions = recentAdditions
        self.activeSources = activeSources
    }

    /// Eingaben zum Zustand; `nil` vor dem ersten Snapshot. Eben in den Papierkorb gelegte Apps (`trashedApps`) fehlen
    /// darin schon, bevor der nächste Scan sie bestätigt.
    public init?(state: MonitoringState, recentAdditions: [HistoryEvent], trashedApps: TrashedApps = TrashedApps()) {
        guard let snapshot = state.snapshot else { return nil }
        self.init(
            snapshot: trashedApps.applied(to: snapshot), findings: state.findings, events: state.recentEvents,
            recentAdditions: recentAdditions, activeSources: state.activeSources
        )
    }

    public func make(now: Date) -> PresentationSnapshot {
        PresentationSnapshot.make(
            snapshot: snapshot, findings: findings, events: events, recentAdditions: recentAdditions,
            activeSources: activeSources, now: now
        )
    }

    /// Berechnet die Anzeige-Daten außerhalb des Main Actors.
    @concurrent
    public static func compute(_ input: PresentationInput) async -> PresentationSnapshot {
        input.make(now: .now)
    }
}

/// Hält die Anzeige-Daten aktuell, ohne den Main Actor zu belasten: Neu gerechnet wird nur, wenn sich die Eingaben
/// geändert haben, und zwar im Hintergrund. Kommt während einer Berechnung eine neuere Eingabe, wird die ältere
/// abgebrochen und ihr Ergebnis – falls sie dennoch fertig wird – verworfen.
@MainActor
public final class PresentationPipeline {
    public typealias Compute = @Sendable (PresentationInput) async -> PresentationSnapshot

    private let compute: Compute
    private let deliver: @MainActor (PresentationSnapshot?) -> Void
    /// Zuletzt angeforderte Eingabe; `.none` vor dem ersten `update`.
    private var lastInput: PresentationInput??
    private var generation = RequestGeneration()
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - compute: Berechnung; Standard `PresentationInput.compute` (außerhalb des Main Actors).
    ///   - deliver: übernimmt das Ergebnis der jüngsten Eingabe; `nil` ohne Snapshot.
    public init(
        compute: @escaping Compute = PresentationInput.compute,
        deliver: @escaping @MainActor (PresentationSnapshot?) -> Void
    ) {
        self.compute = compute
        self.deliver = deliver
    }

    /// Übernimmt neue Eingaben; `nil` (kein Snapshot) leert die Anzeige-Daten sofort.
    public func update(_ input: PresentationInput?) {
        guard lastInput != .some(input) else { return }
        lastInput = .some(input)
        task?.cancel()
        guard let input else {
            generation.invalidate()
            task = nil
            deliver(nil)
            return
        }
        let token = generation.begin()
        task = Task { [compute] in
            let presentation = await compute(input)
            guard !Task.isCancelled, generation.isCurrent(token) else { return }
            deliver(presentation)
        }
    }

    /// Wartet, bis die jüngste Berechnung fertig ist (für Tests).
    func waitUntilIdle() async {
        await task?.value
    }
}
