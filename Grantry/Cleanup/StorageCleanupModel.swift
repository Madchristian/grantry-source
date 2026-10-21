import Foundation
import ManagerKit
import Observation
import os

/// Zustand des Segments „Speicher“ (Spec Speicher §2): Scan auf Knopfdruck mit inkrementellen Ergebnissen, Auswahl,
/// Löschen mit Nachprüfung je Eintrag, Ergebnis und „Zuletzt aufgeräumt“; dazu die Time-Machine-Vorschläge (#227) mit
/// Ausnehmen und Wiedersichern nach Bestätigung. Lebt im `AppModel`.
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
    /// Time-Machine-Vorschläge (#227); `nil` bis zum ersten vollständigen Scan.
    private(set) var timeMachine: TimeMachineReport?
    var timeMachineSelection: Set<String> = []
    let preferences = StoragePreferences()

    @ObservationIgnored private let remover: StorageRemover
    @ObservationIgnored private let timeMachineExclusions: TimeMachineExclusions
    @ObservationIgnored private let log: CleanupLog
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Ablage des Protokolls (für „Im Finder zeigen“).
    var logURL: URL { log.url }

    init(remover: StorageRemover, timeMachineExclusions: TimeMachineExclusions = TimeMachineExclusions(), log: CleanupLog) {
        self.remover = remover
        self.timeMachineExclusions = timeMachineExclusions
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
            let date = Self.write(outcomes, to: log)
            guard let self else { return }
            self.show(outcomes, at: date)
            self.phase = .scanned
            // Aufgeräumtes und betroffene Kategorien vor dem Nachscan verwerfen: Bricht er ab, bietet die Liste weder
            // Entferntes noch Befehle mit veralteter Größe erneut an.
            self.selection.subtract(cleanedIDs)
            self.reports.removeAll { affected.contains($0.id) }
            self.scan(only: affected)
        }
    }

    /// Bestätigte Time-Machine-Änderung an den gewählten Vorschlägen, die sie tatsächlich ändert; danach den Status neu
    /// lesen (Größen bleiben, gemessen wird nicht erneut).
    func changeTimeMachine(_ change: TimeMachineChange) {
        guard phase == .scanned, let report = timeMachine else { return }
        let targets = TimeMachinePresentation.targets(of: change, in: report.suggestions, selection: timeMachineSelection)
        guard !targets.isEmpty else { return }
        phase = .cleaning
        let exclusions = timeMachineExclusions, log = log
        let candidates = report.suggestions.map(\.candidate)
        let sizes = Dictionary(report.suggestions.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        task = Task { [weak self] in
            let outcomes = await exclusions.apply(change, to: targets)
            let date = Self.write(outcomes, to: log)
            self?.show(outcomes, at: date)
            self?.timeMachineSelection.subtract(targets.map(\.id))
            let refreshed = await exclusions.scan(candidates, knownSizes: sizes)
            guard let self else { return }
            self.timeMachine = refreshed
            self.phase = .scanned
        }
    }

    /// Schreibt die Ausgänge ins `CleanupLog`; ein Fehler wird nur protokolliert.
    private static func write(_ outcomes: [StorageCleanOutcome], to log: CleanupLog) -> Date {
        let date = Date.now
        do {
            try log.append(outcomes, at: date)
        } catch {
            logger.error("Aufräumprotokoll nicht geschrieben: \(error.localizedDescription, privacy: .public)")
        }
        return date
    }

    /// Letztes Ergebnis und „Zuletzt aufgeräumt“ – aus dem Speicher statt neu gelesen: Ein fehlgeschlagenes Schreiben
    /// verbirgt den Lauf so nicht.
    private func show(_ outcomes: [StorageCleanOutcome], at date: Date) {
        lastOutcomes = outcomes
        let entries = outcomes.reversed().map { CleanupLogEntry(date: date, outcome: $0) }
        recentLog = Array((entries + recentLog).prefix(Self.recentLogLimit))
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
            timeMachine = nil
            timeMachineSelection = []
        }
        let exclusions = timeMachineExclusions
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
            // Nach dem vollständigen Scan, mit dessen Größen: Große Ordner werden nicht doppelt gemessen.
            if ids == nil, let reports = self?.reports {
                let report = await exclusions.scan(StorageCatalog.timeMachineCandidates(configuration),
                                                   knownSizes: TimeMachineExclusions.knownSizes(from: reports))
                guard !Task.isCancelled, let self else { return }
                self.timeMachine = report
                self.timeMachineSelection = Set(report.suggestions.filter(\.isPreselected).map(\.id))
            }
            let volume = await VolumeUsage.of(configuration.home)
            guard !Task.isCancelled, let self else { return }
            // Nach einem abgebrochenen Scan fehlen Kategorien auch nach dem Nachscan einzelner – dann keine Bilanz.
            self.volume = Set(order).isSubset(of: self.reports.map(\.id)) ? volume : nil
            self.phase = .scanned
        }
    }
}
