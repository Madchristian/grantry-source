import Foundation

/// Orca-Worktrees (#255, nur Bericht): Orca legt jeden Worktree als verknüpften Git-Worktree in seinem Arbeitsordner an,
/// `<Arbeitsordner>/<Repo>/<Worktree>` oder ohne Verschachtelung `<Arbeitsordner>/<Worktree>`. Je Worktree eine Zeile
/// mit Größe, Branch und jüngster Änderung im Unterbaum (`FileSizeMeasuring.summarize`).
///
/// Nicht wählbar: Ob ein Worktree offene Änderungen oder nur lokale Commits hat, ließe sich nur mit `git` belegen (der
/// Shim `/usr/bin/git` öffnet ohne Command Line Tools einen Installationsdialog), und Orca führt eigenen Zustand
/// (Terminals, laufende Worker), den ein Papierkorb nicht aufräumt. Entfernt wird in Orca. Erkannt wird nur, was
/// `GitWorktree` als verknüpften Worktree belegt; Hauptklone, Symlinks und Verstecktes nicht.
struct OrcaWorktreesProvider: StorageCategoryProvider {
    static let categoryID = "orcaWorktrees"

    let workspaceRoot: String
    let measurer: any FileSizeMeasuring

    var category: StorageCategory {
        StorageCategory(id: Self.categoryID, title: "Orca-Worktrees",
                        summary: "Arbeitskopien aus Orca; offene Änderungen prüft Grantry nicht. Entfernen in Orca (`orca worktree rm`).",
                        risk: .reportOnly, roots: [workspaceRoot])
    }

    /// Ein Worktree: Ordner, Anzeige und Git-Ordner.
    private struct Worktree {
        let entry: RootListing.Entry
        let title: String
        let gitDirectory: String
    }

    func scan() async -> StorageCategoryReport {
        let top = listing(of: [workspaceRoot])
        var found: [Worktree] = []
        var unreadable = top.unreadableRoots
        for folder in top.entries where folder.identity.type == .directory {
            if let worktree = Self.worktree(folder, title: folder.name) {
                found.append(worktree)
                continue
            }
            let repository = listing(of: [folder.path])
            unreadable += repository.unreadableRoots
            found += repository.entries.filter { $0.identity.type == .directory }
                .compactMap { Self.worktree($0, title: "\(folder.name) – \($0.name)") }
        }
        let summaries = await ConcurrentMeasurement.summaries(of: found.map(\.entry.path), measurer: measurer)
        let items = zip(found, summaries).map { worktree, summary in
            StorageItem(id: worktree.entry.path, title: worktree.title, path: worktree.entry.path, size: summary.size,
                        removal: .none, isPreselected: false,
                        detail: "\(Self.headText(worktree.gitDirectory)), \(summary.changeText)",
                        identity: worktree.entry.identity)
        }
        return StorageCategoryReport(category: category, status: top.status, items: items, unreadablePaths: unreadable)
    }

    private func listing(of folders: [String]) -> RootListing {
        RootListing(roots: folders) { !RawPath.isHidden($0) }
    }

    private static func worktree(_ entry: RootListing.Entry, title: String) -> Worktree? {
        GitWorktree.linkedGitDirectory(of: entry.path).map { Worktree(entry: entry, title: title, gitDirectory: $0) }
    }

    private static func headText(_ gitDirectory: String) -> String {
        switch GitWorktree.head(inGitDirectory: gitDirectory) {
        case .branch(let name): "Branch \(name)"
        case .detached: "Losgelöster HEAD"
        case nil: "Branch unbekannt"
        }
    }
}
