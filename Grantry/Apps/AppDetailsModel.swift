import ManagerKit
import Observation

/// Größe und „zuletzt benutzt“ der installierten Apps für die Oberfläche (Spec v3 §2 „nachgeladen“), über den
/// `AppDetailsLoader` – eine App zur Zeit, sichtbare Zeilen und das Detail zuerst. Was aus dem Bild scrollt, wird nicht
/// mehr angefragt (`withdraw(_:)`); alle Apps lädt es nur, solange die Liste nach Größe oder Nutzung sortiert ist
/// (`loadsAll`). Der Loader merkt sich Größen je Fingerabdruck, ein erneutes Laden kostet daher nur die Spotlight-Abfrage.
@MainActor
@Observable
final class AppDetailsModel {
    /// Geladene Angaben je `InstalledApp.id`; fehlt eine App, wurde sie (in dieser Version) noch nicht geladen.
    private(set) var details: [String: AppUsageDetails] = [:]
    @ObservationIgnored private let loader: AppDetailsLoader
    /// Stand (Version) je App im aktuellen Snapshot.
    @ObservationIgnored private var currentKeys: [String: String] = [:]
    /// Stand, zu dem die Angaben in `details` geladen wurden.
    @ObservationIgnored private var loadedKeys: [String: String] = [:]
    /// Apps, deren Angaben seit dem letzten `refreshUsage()` geladen wurden.
    @ObservationIgnored private var fresh: Set<String> = []
    /// Angefragte Apps in Reihenfolge der Anfrage; eine App steht so oft darin, wie sie angezeigt wird.
    @ObservationIgnored private var visible: [String] = []
    /// Alle Apps, solange `loadsAll` gilt.
    @ObservationIgnored private var background: [String] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(loader: AppDetailsLoader = AppDetailsLoader()) {
        self.loader = loader
    }

    /// Übernimmt die Apps eines neuen Snapshots: Angaben entfernter oder geänderter Apps (Version) werden verworfen.
    func update(for apps: [InstalledApp]) {
        currentKeys = Dictionary(apps.map { ($0.id, $0.versionText ?? "") }, uniquingKeysWith: { first, _ in first })
        for id in details.keys where currentKeys[id] != loadedKeys[id] {
            details[id] = nil
            loadedKeys[id] = nil
            fresh.remove(id)
        }
        if !background.isEmpty { background = apps.map(\.id) }
        pump()
    }

    /// Lädt eine angezeigte App, sofern ihre Angaben nicht aktuell sind.
    func request(_ id: String) {
        visible.append(id)
        pump()
    }

    /// Die App wird (an dieser Stelle) nicht mehr angezeigt; noch nicht begonnenes Laden entfällt.
    func withdraw(_ id: String) {
        if let index = visible.firstIndex(of: id) { visible.remove(at: index) }
    }

    /// Lädt alle Apps des Snapshots (für die Sortierung nach Größe oder Nutzung) bzw. nur noch die angezeigten.
    func setLoadsAll(_ loadsAll: Bool) {
        background = loadsAll ? Array(currentKeys.keys).sorted() : []
        pump()
    }

    /// Lädt die angezeigten Apps erneut (Bereich geöffnet – „zuletzt benutzt“ frisch); bis dahin bleiben die alten
    /// Angaben sichtbar.
    func refreshUsage() {
        fresh.removeAll()
        pump()
    }

    private func pump() {
        guard worker == nil, nextID() != nil else { return }
        worker = Task {
            while let id = nextID() {
                let key = currentKeys[id]
                let loaded = await loader.details(for: id)
                guard currentKeys[id] == key else { continue }
                details[id] = loaded
                loadedKeys[id] = key
                fresh.insert(id)
            }
            worker = nil
        }
    }

    private func nextID() -> String? {
        (visible + background).first { id in
            guard let key = currentKeys[id] else { return false }
            return key != loadedKeys[id] || !fresh.contains(id)
        }
    }
}
