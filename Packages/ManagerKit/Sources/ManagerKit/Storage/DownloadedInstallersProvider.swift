import Foundation

/// Heruntergeladene Installer (#226, VirtualBuddy: `.ipsw`): reguläre Dateien mit passender Endung direkt in den
/// Wurzeln der Kategorie. Vorausgewählt sind Installer, die seit `minimumAgeDays` weder geladen noch geändert wurden.
/// Immer in den Papierkorb, auch bei Risiko „niedrig“: ein Installer ist groß und nicht schnell neu geladen.
struct DownloadedInstallersProvider: StorageCategoryProvider {
    let category: StorageCategory
    /// Endungen in Kleinbuchstaben, z. B. `ipsw`.
    let extensions: Set<String>
    let minimumAgeDays: Int
    var now: @Sendable () -> Date = { Date() }
    let measurer: any FileSizeMeasuring

    func scan() async -> StorageCategoryReport {
        let listing = RootListing(roots: category.roots) { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let files = listing.entries.filter { $0.identity.type == .regularFile }
        let limit = now().addingTimeInterval(-Double(minimumAgeDays) * 86_400)
        let sizes = await ConcurrentMeasurement.sizes(of: files.map(\.path), measurer: measurer)
        let items = zip(files, sizes).map { file, size in
            let date = Self.newestDate(of: file.path)
            return StorageItem(id: file.path, title: file.name, path: file.path, size: size, removal: .trash,
                               isPreselected: date.map { $0 < limit } ?? false,
                               detail: date.map { "Vom \($0.formatted(date: .abbreviated, time: .omitted))" },
                               identity: file.identity)
        }
        return StorageCategoryReport(category: category, status: listing.status, items: items,
                                     unreadablePaths: listing.unreadableRoots)
    }

    /// Das jüngere von Erstellungs- und Änderungsdatum: Ein Download kann das Änderungsdatum des Servers tragen.
    private static func newestDate(of path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return [attributes?[.creationDate], attributes?[.modificationDate]].compactMap { $0 as? Date }.max()
    }
}
