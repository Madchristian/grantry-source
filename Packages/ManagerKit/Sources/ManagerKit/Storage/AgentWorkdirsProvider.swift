import Darwin
import Foundation

/// Arbeitsordner von KI-Agenten-Sessions (#229): Claude Code legt je Session `/private/tmp/claude-<uid>/<Projekt>/<Session>`
/// an (`scratchpad`, `tasks`, oft große Build- und Testergebnisse), Codex direkte Einträge in `~/.codex/.tmp`. macOS leert
/// `/private/tmp` erst beim Neustart. Je Session eine Zeile mit Projekt, Größe und jüngster Änderung im Unterbaum – beides
/// in einem Durchgang (`FileSizeMeasuring.summarize`: `lstat`, Symlinks nicht verfolgt, begrenzt durch die Messfrist).
///
/// Nur Ordner der eigenen UID; eine fremde Wurzel (etwa ein vorab angelegtes `claude-<uid>` im für alle beschreibbaren
/// `/private/tmp`) wird nicht betreten. Vorausgewählt nur, was seit `minimumAgeDays` vollständig unverändert ist und
/// worin kein eigener Prozess eine Datei offen oder seinen Arbeitsordner hat (`ProcessLock.anyProcess`); ist die
/// Prozessliste nicht lesbar, nichts. Risiko „niedrig“, aber immer Papierkorb: Eine laufende Session ohne offene Datei
/// darin ist nicht sicher erkennbar. Der `StorageRemover` prüft die Sperre unmittelbar vor dem Papierkorb erneut.
struct AgentWorkdirsProvider: StorageCategoryProvider {
    static let categoryID = "agentWorkdirs"

    let claudeRoot: String
    let codexRoot: String
    /// Für lesbare Projektnamen (`-Users-name-Projekt` → `Projekt`).
    let home: String
    let minimumAgeDays: Int
    let measurer: any FileSizeMeasuring
    var openFiles: any OpenFileProbing = LibprocOpenFileProbe()
    var now: @Sendable () -> Date = { Date() }
    var userID: uid_t = getuid()

    var category: StorageCategory {
        StorageCategory(id: Self.categoryID, title: "Agenten-Arbeitsordner",
                        summary: "Arbeitsordner von Claude-Code- und Codex-Sessions; unveränderte seit \(minimumAgeDays) Tagen sind vorausgewählt.",
                        risk: .low, roots: [claudeRoot, codexRoot], processLock: .anyProcess)
    }

    /// Eine Session: Pfad, Anzeige und Werkzeug.
    private struct Session {
        let entry: RootListing.Entry
        let title: String
        let tool: String
    }

    func scan() async -> StorageCategoryReport {
        let claude = listing(of: [claudeRoot])
        let projects = claude.entries.filter(isOwnDirectory)
        let sessions = listing(of: projects.map(\.path))
        let codex = listing(of: [codexRoot])
        let found = sessions.entries.filter(isOwnDirectory).map { entry in
            let project = ((entry.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return Session(entry: entry, title: "\(Self.projectName(project, home: home)) – Session \(entry.name.prefix(8))",
                           tool: "Claude Code")
        } + codex.entries.filter(isOwnDirectory).map { Session(entry: $0, title: "Codex – \($0.name)", tool: "Codex") }
        let summaries = await ConcurrentMeasurement.summaries(of: found.map(\.entry.path), measurer: measurer)
        let usage = openFiles.usage(for: category.processLock)
        let limit = now().addingTimeInterval(-Double(minimumAgeDays) * 86_400)
        let items = zip(found, summaries).map { session, summary in
            let lockReason = usage?.lockReason(for: session.entry.path, lock: .anyProcess)
            let isIdle = summary.newestModification.map { $0 < limit } ?? false
            return StorageItem(id: session.entry.path, title: session.title, path: session.entry.path, size: summary.size,
                               removal: .trash, isPreselected: usage != nil && lockReason == nil && isIdle,
                               detail: lockReason ?? Self.changeText(summary.newestModification, tool: session.tool),
                               identity: session.entry.identity)
        }
        let unreadable = claude.unreadableRoots + sessions.unreadableRoots + codex.unreadableRoots
        let status: StorageCategoryStatus = [claude.status, codex.status].contains(.available) ? .available
            : [claude.status, codex.status].contains(.needsFullDiskAccess) ? .needsFullDiskAccess : .notInstalled
        return StorageCategoryReport(category: category, status: status, items: items, unreadablePaths: unreadable)
    }

    /// Direkte, nicht versteckte Einträge der Ordner; Wurzeln eines fremden Benutzers gelten als nicht vorhanden.
    private func listing(of folders: [String]) -> RootListing {
        RootListing(roots: folders.filter { isOwnDirectory(path: $0) }) { !RawPath.isHidden($0) }
    }

    private func isOwnDirectory(_ entry: RootListing.Entry) -> Bool {
        entry.identity.type == .directory && isOwnDirectory(path: entry.path)
    }

    private func isOwnDirectory(path: String) -> Bool {
        guard let info = FileType.linkStatus(of: path) else { return false }
        return FileType.isDirectory(info) && info.st_uid == userID
    }

    /// Lesbarer Projektname: Claude Code ersetzt im Projektpfad jedes Zeichen außer Buchstaben und Ziffern durch `-`;
    /// der so kodierte Benutzerordner am Anfang entfällt, der Benutzerordner selbst wird `~`.
    static func projectName(_ folder: String, home: String) -> String {
        let encodedHome = String(home.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        if folder == encodedHome { return "~" }
        return folder.hasPrefix(encodedHome + "-") ? String(folder.dropFirst(encodedHome.count + 1)) : folder
    }

    /// Ohne belegte jüngste Änderung (Frist, nicht lesbare Teile) ehrlich offen.
    private static func changeText(_ newest: Date?, tool: String) -> String {
        guard let newest else { return "\(tool), zuletzt geändert: nicht vollständig geprüft" }
        return "\(tool), zuletzt geändert am \(newest.formatted(date: .abbreviated, time: .shortened))"
    }
}
