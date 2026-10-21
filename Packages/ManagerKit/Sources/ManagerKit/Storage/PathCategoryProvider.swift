import Foundation

/// Generische Kategorie (DRY): Jeder direkte Eintrag der Wurzeln ist ein Eintrag. Ausgelassen werden versteckte Namen,
/// Apple-Kennungen (`com.apple.…`), `excludedNames` (z. B. `Homebrew`, eigene CLI-Kategorie) und Symlinks.
/// Risiko „niedrig“ wird endgültig gelöscht, „mittel“ geht in den Papierkorb. Vorausgewählt sind nur Ordner mit Risiko
/// „niedrig“, deren Größenmessung ein Ergebnis hat (#220); lose Dateien (z. B. `INSTALLATION`) erscheinen, sind aber nie
/// vorausgewählt. Einträge, die `StorageCategory.processLock` gerade sperrt, nennen den Grund und sind nicht
/// vorausgewählt (#226). Größen begrenzt parallel.
struct PathCategoryProvider: StorageCategoryProvider {
    let category: StorageCategory
    var excludedNames: Set<String> = []
    let measurer: any FileSizeMeasuring
    var openFiles: any OpenFileProbing = LibprocOpenFileProbe()

    func scan() async -> StorageCategoryReport {
        let listing = RootListing(roots: category.roots, including: isCandidate)
        let entries = listing.entries
        let sizes = await ConcurrentMeasurement.sizes(of: entries.map(\.path), measurer: measurer)
        // Beim Scan nur Anzeige und Vorauswahl; ist die Prozessliste nicht lesbar, sperrt erst der `StorageRemover`.
        let usage = openFiles.usage(for: category.processLock)
        let items = zip(entries, sizes).map { entry, size in
            let lockReason = category.processLock.flatMap { usage?.lockReason(for: entry.path, lock: $0) }
            return StorageItem(id: entry.path, title: entry.name, path: entry.path, size: size,
                               removal: category.risk == .low ? .delete : .trash,
                               isPreselected: category.risk == .low && entry.identity.type == .directory && lockReason == nil
                                   && size.permitsPreselection,
                               detail: lockReason, identity: entry.identity)
        }
        return StorageCategoryReport(category: category, status: listing.status, items: items,
                                     unreadablePaths: listing.unreadableRoots)
    }

    private func isCandidate(_ name: String) -> Bool {
        !RawPath.isHidden(name) && !name.lowercased().hasPrefix("com.apple.") && !excludedNames.contains(name)
    }
}

/// Direkte Einträge der Wurzeln einer Kategorie ohne Symlinks, mit Status (DRY für `PathCategoryProvider` und
/// `DownloadedInstallersProvider`): keine Wurzel vorhanden → nicht installiert, keine lesbar → Festplattenvollzugriff
/// nötig; unlesbare Wurzeln stehen in `unreadableRoots`.
struct RootListing {
    struct Entry {
        let path: String
        let name: String
        let identity: FileIdentity
    }

    let entries: [Entry]
    let unreadableRoots: [String]
    let status: StorageCategoryStatus

    init(roots: [String], including isCandidate: (String) -> Bool) {
        var entries: [Entry] = []
        var existingRoots = 0, unreadableRoots: [String] = []
        for root in roots where FileIdentity.of(root)?.type == .directory {
            existingRoots += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                unreadableRoots.append(root)
                continue
            }
            for name in names.sorted() where isCandidate(name) {
                let path = root + "/" + name
                guard let identity = FileIdentity.of(path), identity.type != .symbolicLink else { continue }
                entries.append(Entry(path: path, name: name, identity: identity))
            }
        }
        self.entries = entries
        self.unreadableRoots = unreadableRoots
        status = existingRoots == 0 ? .notInstalled
            : unreadableRoots.count == existingRoots ? .needsFullDiskAccess : .available
    }
}
