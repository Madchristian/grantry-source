import Foundation
import GrantryShared
import Observation
import os

/// App-Verlauf (Spec 2026-11-06 §6 Stufe 2): verbucht jeden Takt des Task-Managers (`TaskManagerModel.onFrame`). Einen
/// eigenen Dauerprozess gibt es nicht – **der Verlauf deckt nur Zeiten ab, in denen Grantry gemessen hat** (Task-Manager
/// sichtbar); jede Stunde merkt sich ihre gemessene Zeit. Geschrieben wird höchstens alle `flushInterval`, beim
/// Stundenwechsel, beim Ausblenden des Task-Managers und beim Beenden der App (`flush()`); dabei fallen Stunden älter
/// als 30 Tage weg. Die 30 Tage gelten auch ohne neue Takte: `load()` merkt gekürzte Stunden zum Schreiben vor, und
/// `enforceRetention()` kürzt die Datei, ohne dass der Task-Manager geöffnet wird.
@MainActor
@Observable
public final class AppUsageModel {
    public static let flushInterval: TimeInterval = 300
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "task-manager")

    public private(set) var history = AppUsageHistory()
    /// Hinweis zur vorgefundenen Datei (beiseitegelegt bzw. nicht lesbar, #353), sonst der letzte Fehler beim Schreiben
    /// oder Löschen; `nil` nach Erfolg. Der Hinweis bleibt bis „Verlauf löschen“.
    public var lastError: String? { writeError ?? loadProblem?.readableDescription }

    private var writeError: String?
    /// Problem beim Lesen der Datei; blockiert es das Schreiben, bleibt die Datei bis „Verlauf löschen“ unangetastet.
    private var loadProblem: AppUsageLoadProblem?

    @ObservationIgnored private let store: AppUsageStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var lastFlush: Date?

    public init(store: AppUsageStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Liest die Datei einmal (beim Öffnen des Task-Managers, nicht beim App-Start).
    public func load() {
        guard !isLoaded else { return }
        isLoaded = true
        history = loadStore()
        pruneHistory()
        lastFlush = now()
    }

    /// Hält die Aufbewahrung von 30 Tagen ein, ohne dass Takte eintreffen (die Datei sonst bis zum nächsten Öffnen des
    /// Task-Managers behielte, was längst abgelaufen ist). Ohne Datei kostet das nur eine Existenzprüfung; sonst höchstens
    /// ein Lesen und nur bei abgelaufenen Stunden ein Schreiben – bleibt nichts übrig, entfällt die Datei. Eine nicht
    /// geladene Historie bleibt dabei ungeladen, sie belegt also keinen Speicher.
    public func enforceRetention() {
        if isLoaded {
            if pruneHistory() { flush() }
        } else if store.fileExists, let pruned = prunedCopy(of: loadStore()) {
            write(pruned)
        }
    }

    /// Verbucht einen Takt; ohne Prozessmessung oder verstrichene Zeit geschieht nichts.
    public func record(_ frame: TaskManagerFrame, apps: [RunningApp], currentUID: UInt32,
                       network: [ProcessKey: Double]?) {
        load()
        let date = now()
        guard let sample = AppUsageSample.make(frame: frame, apps: apps, currentUID: currentUID, network: network,
                                               at: date) else { return }
        history.add(sample)
        isDirty = true
        guard let lastFlush else { return }
        if date.timeIntervalSince(lastFlush) >= Self.flushInterval
            || AppUsageHistory.hourStart(of: lastFlush) != AppUsageHistory.hourStart(of: date) {
            flush()
        }
    }

    /// Schreibt offene Änderungen.
    public func flush() {
        guard isDirty else { return }
        history.prune(now: now())
        if write(history) { isDirty = false }
        lastFlush = now()
    }

    /// „Verlauf löschen“: Speicher und Datei.
    public func clear() {
        isLoaded = true
        history = AppUsageHistory()
        isDirty = false
        do {
            try store.remove()
            loadProblem = nil
            writeError = nil
        } catch {
            writeError = error.readableDescription
        }
    }

    /// Liest die Datei; eine unlesbare merkt sich ihr Problem und ergibt einen leeren Verlauf.
    private func loadStore() -> AppUsageHistory {
        do {
            return try store.load()
        } catch {
            loadProblem = error as? AppUsageLoadProblem ?? .unreadable(reason: error.readableDescription)
            Self.logger.error("App-Verlauf nicht lesbar: \(error.readableDescription, privacy: .public)")
            return AppUsageHistory()
        }
    }

    /// Wendet die Aufbewahrung auf den Verlauf im Speicher an; hat sie etwas entfernt, gilt der Stand als geändert und
    /// wird beim nächsten `flush()` geschrieben.
    @discardableResult
    private func pruneHistory() -> Bool {
        guard let pruned = prunedCopy(of: history) else { return false }
        history = pruned
        isDirty = true
        return true
    }

    /// `history` nach der Aufbewahrung; `nil`, wenn sie nichts entfernt hat.
    private func prunedCopy(of history: AppUsageHistory) -> AppUsageHistory? {
        var pruned = history
        pruned.prune(now: now())
        return pruned == history ? nil : pruned
    }

    /// Speichert `history`; eine leere Historie entfernt die Datei samt Zwischendateien, statt eine leere zu schreiben.
    @discardableResult
    private func write(_ history: AppUsageHistory) -> Bool {
        guard loadProblem?.blocksWriting != true else { return false }
        do {
            if history.isEmpty { try store.remove() } else { try store.save(history) }
            writeError = nil
            return true
        } catch {
            writeError = error.readableDescription
            Self.logger.error("App-Verlauf nicht gespeichert: \(error.readableDescription, privacy: .public)")
            return false
        }
    }
}
