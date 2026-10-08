import Foundation
import ManagerKit
import Observation

/// Zustand von „Installation beobachten“ (#127): laufende Beobachtung samt Live-Zahl neuer Einträge, gespeicherte
/// Beobachtungen, Start (mit Rückfrage bei Quellfehlern) und Ende. Lebt im `AppModel`, damit Menüleiste und Hauptfenster
/// denselben Stand zeigen.
@MainActor
@Observable
final class ObservationModel {
    /// Start, dessen Scan Quellen nicht lesen konnte – wartet auf „Trotzdem starten“.
    struct PendingStart: Identifiable {
        let id = UUID()
        let name: String
        let note: String?
        let baseline: Snapshot
    }

    enum Phase: Equatable {
        case idle
        /// Scan für den Ausgangsstand läuft.
        case starting
        /// Abschließender Scan läuft.
        case finishing
    }

    private(set) var active: InstallationObservation?
    private(set) var summaries: [ObservationSummary] = []
    /// Neue Einträge seit dem Start, gegen den jüngsten Scan; `nil` ohne laufende Beobachtung.
    private(set) var liveAddedCount: Int?
    private(set) var phase = Phase.idle
    var pendingStart: PendingStart?
    /// Lesbare Meldung des letzten Fehlers (Ablage, Scan).
    var errorMessage: String?

    @ObservationIgnored private let store: (any ObservationStore)?
    @ObservationIgnored private let scanner: (any ScanRequesting)?

    init(store: (any ObservationStore)?, scanner: (any ScanRequesting)?) {
        self.store = store
        self.scanner = scanner
    }

    var isAvailable: Bool { store != nil && scanner != nil }
    var isBusy: Bool { phase != .idle }

    /// Lädt laufende und gespeicherte Beobachtungen.
    func load() async {
        guard let store else { return }
        do {
            active = try await store.activeObservation()
            summaries = try await store.observationSummaries()
        } catch {
            errorMessage = error.readableDescription
        }
    }

    /// Frischt die Live-Zahl nach einem neuen Scan auf.
    func update(with snapshot: Snapshot) {
        guard let active else { return liveAddedCount = nil }
        liveAddedCount = ObservationBalance(baseline: active.baseline, final: snapshot).addedCount
    }

    /// Scannt sofort und friert das Ergebnis als Ausgangsstand ein; mit Quellfehlern wartet der Start auf
    /// `confirmStart(_:)`. Wird der aufrufende Task abgebrochen („Abbrechen“ im Blatt), entsteht keine Beobachtung.
    func start(name: String, note: String?) async {
        guard let scanner, !isBusy, active == nil else { return }
        errorMessage = nil
        phase = .starting
        defer { phase = .idle }
        let baseline = await Self.scan(with: scanner)
        guard !Task.isCancelled else { return }
        guard let baseline else {
            errorMessage = String(localized: "Der Scan für den Ausgangsstand ist ausgeblieben – bitte erneut versuchen.")
            return
        }
        if baseline.sourceErrors.isEmpty {
            await commit(name: name, note: note, baseline: baseline)
        } else {
            pendingStart = PendingStart(name: name, note: note, baseline: baseline)
        }
    }

    /// „Trotzdem starten“ trotz Quellfehlern (der Wert kommt aus dem Alert – dessen Binding hat `pendingStart` dann schon
    /// zurückgesetzt).
    func confirmStart(_ pending: PendingStart) async {
        pendingStart = nil
        errorMessage = nil
        await commit(name: pending.name, note: pending.note, baseline: pending.baseline)
    }

    private func commit(name: String, note: String?, baseline: Snapshot) async {
        guard let store else { return }
        let observation = InstallationObservation(name: name, note: note, startedAt: baseline.takenAt, baseline: baseline)
        do {
            try await store.startObservation(observation)
            active = observation
            liveAddedCount = 0
        } catch {
            errorMessage = error.readableDescription
        }
        await load()
    }

    /// Scannt abschließend, speichert den Endstand und liefert die beendete Beobachtung (für die Bilanz).
    @discardableResult
    func finish() async -> InstallationObservation? {
        guard let store, let scanner, let active, !isBusy else { return nil }
        errorMessage = nil
        phase = .finishing
        defer { phase = .idle }
        guard let final = await Self.scan(with: scanner) else {
            errorMessage = String(localized: "Der abschließende Scan ist ausgeblieben – bitte erneut versuchen.")
            return nil
        }
        do {
            let finished = try await store.finishObservation(id: active.id, final: final, at: final.takenAt)
            self.active = nil
            liveAddedCount = nil
            await load()
            return finished
        } catch {
            errorMessage = error.readableDescription
            await load()
            return nil
        }
    }

    /// Längste Wartezeit auf den Scan für Ausgangs- bzw. Endstand.
    static let scanTimeout: Duration = .seconds(120)

    /// Frischer Scan, höchstens `scanTimeout` lang; `nil` bei Zeitüberschreitung (der wartende Task wird dann abgebrochen,
    /// `ScanRequesting` liefert daraufhin `nil`).
    private static func scan(with scanner: any ScanRequesting) async -> Snapshot? {
        await withTaskGroup(of: Snapshot?.self) { group in
            group.addTask { await scanner.scan(startedNotBefore: .now) }
            group.addTask {
                try? await Task.sleep(for: scanTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Die vollständige Beobachtung `id`; `nil`, wenn sie fehlt oder nicht lesbar ist.
    func observation(id: UUID) async -> InstallationObservation? {
        guard let store else { return nil }
        do {
            return try await store.observation(id: id)
        } catch {
            errorMessage = error.readableDescription
            return nil
        }
    }

    func delete(id: UUID) async {
        guard let store else { return }
        errorMessage = nil
        do {
            try await store.deleteObservation(id: id)
        } catch {
            errorMessage = error.readableDescription
        }
        await load()
    }

    /// Hält fest, was ein Aufräumen aus der Beobachtung `id` bewirkt hat.
    func recordCleanup(_ report: RemovalReport, observationID id: UUID) async {
        // Nur protokollieren, wenn etwas versucht wurde – nicht, wenn alles übersprungen wurde (keine Überwachung, Abbruch).
        let attempted = report.entries.contains { if case .skipped = $0.result { false } else { true } }
        guard let store, attempted else { return }
        errorMessage = nil
        do {
            try await store.appendCleanup(ObservationCleanupRecord(report, performedAt: .now), toObservation: id)
        } catch {
            errorMessage = error.readableDescription
        }
        await load()
    }

    /// Statuszeile für Menüleiste und Übersicht; `nil` ohne laufende Beobachtung.
    func statusLine(now: Date) -> String? {
        active.map {
            ObservationTexts.statusLine(name: $0.name, startedAt: $0.startedAt, now: now, addedCount: liveAddedCount)
        }
    }
}
