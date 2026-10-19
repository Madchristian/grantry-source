import Foundation
import ManagerKit
import Observation
import os

/// Zustand des Segments „Speicher“ (Spec Speicher §2): Scan auf Knopfdruck mit inkrementellen Ergebnissen, Auswahl,
/// Löschen mit Nachprüfung je Eintrag, Ergebnis und „Zuletzt aufgeräumt“. Lebt im `AppModel`.
@MainActor
@Observable
final class StorageCleanupModel {
    enum Phase: Equatable {
        case idle, scanning, scanned, cleaning
    }

    /// Länge von „Zuletzt aufgeräumt“.
    static let recentLogLimit = 20
    nonisolated private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "storage-cleanup")

    private(set) var phase: Phase = .idle
    private(set) var reports: [StorageCategoryReport] = []
    var selection: Set<String> = []
    private(set) var lastOutcomes: [StorageCleanOutcome] = []
    /// Neueste zuerst.
    private(set) var recentLog: [CleanupLogEntry] = []
    /// Belegung des Volumes, nur wenn für jede Kategorie ein Bericht vorliegt (für „Keiner Kategorie zugeordnet“, #226).
    private(set) var volume: VolumeUsage?
    let preferences = StoragePreferences()

    @ObservationIgnored private let remover: StorageRemover
    @ObservationIgnored private let log: CleanupLog
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Ablage des Protokolls (für „Im Finder zeigen“).
    var logURL: URL { log.url }

    init(remover: StorageRemover, log: CleanupLog) {
        self.remover = remover
        self.log = log
        recentLog = Array(log.read().suffix(Self.recentLogLimit).reversed())
    }

    /// Größte zuerst.
    var sortedReports: [StorageCategoryReport] { reports.sorted { $0.knownBytes > $1.knownBytes } }

    func scan() { scan(only: nil) }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .scanning { phase = reports.isEmpty ? .idle : .scanned }
    }

    /// Bestätigte Auswahl ausführen – in Katalogreihenfolge, weil `reports` sie hält (`StorageCatalog.ordered`); danach
    /// die betroffenen Kategorien neu scannen.
    func clean() {
        let groups = StoragePresentation.selectedItems(in: reports, selection: selection)
        guard phase == .scanned, !groups.isEmpty else { return }
        phase = .cleaning
        let affected = Set(groups.map(\.0.id)), cleanedIDs = Set(groups.flatMap(\.1).map(\.id))
        let remover = remover, log = log
        task = Task { [weak self] in
            var outcomes: [StorageCleanOutcome] = []
            for (report, items) in groups { outcomes += await remover.clean(items, in: report.category) }
            let date = Date.now
            do {
                try log.append(outcomes, at: date)
            } catch {
                Self.logger.error("Aufräumprotokoll nicht geschrieben: \(error.localizedDescription, privacy: .public)")
            }
            guard let self else { return }
            self.lastOutcomes = outcomes
            // Aus dem Speicher statt neu gelesen: Ein fehlgeschlagenes Schreiben verbirgt den Lauf so nicht.
            let entries = outcomes.reversed().map { CleanupLogEntry(date: date, outcome: $0) }
            self.recentLog = Array((entries + self.recentLog).prefix(Self.recentLogLimit))
            self.phase = .scanned
            // Aufgeräumtes und betroffene Kategorien vor dem Nachscan verwerfen: Bricht er ab, bietet die Liste weder
            // Entferntes noch Befehle mit veralteter Größe erneut an.
            self.selection.subtract(cleanedIDs)
            self.reports.removeAll { affected.contains($0.id) }
            self.scan(only: affected)
        }
    }

    private func scan(only ids: Set<String>?) {
        task?.cancel()
        let configuration = StorageCatalog.Configuration(home: NSHomeDirectory(), codeRoots: preferences.codeRoots,
                                                         minimumAgeDays: preferences.minimumAgeDays)
        let catalog = StorageCatalog.providers(configuration)
        let order = catalog.map(\.category.id)
        let providers = catalog.filter { ids?.contains($0.category.id) ?? true }
        if ids == nil {
            reports = []
            selection = []
            lastOutcomes = []
        }
        volume = nil
        phase = .scanning
        task = Task { [weak self] in
            for await report in StorageScanner(providers: providers).scan() {
                // Ein abgebrochener oder ersetzter Scan übernimmt keine gepufferten Berichte mehr.
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Katalogreihenfolge statt Eingangsreihenfolge: Sie bestimmt die Reihenfolge des Aufräumens.
                self.reports = StorageCatalog.ordered(self.reports.filter { $0.id != report.id } + [report], by: order)
                self.selection.subtract(Set(report.items.map(\.id)))
                self.selection.formUnion(report.items.filter { $0.isSelectable && $0.isPreselected }.map(\.id))
            }
            let volume = await VolumeUsage.of(configuration.home)
            guard !Task.isCancelled, let self else { return }
            // Nach einem abgebrochenen Scan fehlen Kategorien auch nach dem Nachscan einzelner – dann keine Bilanz.
            self.volume = Set(order).isSubset(of: self.reports.map(\.id)) ? volume : nil
            self.phase = .scanned
        }
    }
}
