import Foundation

/// `.build` (neben `Package.swift`) und `node_modules` (neben `package.json`) in Projekten unter den Code-Wurzeln,
/// höchstens `maximumDepth` Ordner tief, die seit `minimumAgeDays` unberührt sind: weder die übrigen Einträge des
/// Projekts noch die Artefakt-Ordner samt ihren direkten Einträgen sind jünger (Builds und `npm install` schreiben
/// dort, ohne die Einträge des Projekts anzufassen), ebenso wenig `.git/HEAD` und `.git/index` (Commit, Checkout,
/// Staging) und tiefer liegende Einträge (Bearbeitung ohne Build oder Commit, #220; höchstens `deepEntryBudget`
/// Einträge je Projekt, darüber gilt es im Zweifel als benutzt). Folgt keinen Symlinks, betritt weder versteckte Ordner
/// noch Artefakte. Risiko „mittel“: Papierkorb, nie vorausgewählt. Größen begrenzt parallel.
struct ProjectArtifactsProvider: StorageCategoryProvider {
    static let maximumDepth = 4
    /// Artefakt-Ordner → Manifest, das ein Projekt belegt.
    static let artifacts = [".build": "Package.swift", "node_modules": "package.json"]
    /// Git schreibt sie bei Commit, Checkout und Staging.
    static let gitMarkers = [".git/HEAD", ".git/index"]
    /// Höchstzahl tiefer Einträge, deren Änderungsdatum je Projekt gelesen wird (ein `lstat` je Eintrag).
    static let deepEntryBudget = 10_000

    let roots: [String]
    let minimumAgeDays: Int
    var now: @Sendable () -> Date = { Date() }
    var deepEntryBudget = Self.deepEntryBudget
    let measurer: any FileSizeMeasuring

    var category: StorageCategory {
        StorageCategory(id: "projectArtifacts", title: "Build-Ordner alter Projekte",
                        summary: "`.build` und `node_modules` in Projekten, die länger nicht geändert wurden.",
                        risk: .medium, roots: normalizedRoots)
    }

    /// Wurzeln einmal vereinheitlicht: absolut, `.`/`..`/`//` und `/` am Ende entfernt, ohne Duplikate und ohne Wurzeln,
    /// die in einer anderen konfigurierten liegen. So wird kein Artefakt doppelt gemeldet und der Titel stimmt.
    var normalizedRoots: [String] {
        var unique: [String] = []
        for root in roots.filter({ $0.hasPrefix("/") }).map(Self.lexicallyStandardized) where !unique.contains(root) {
            unique.append(root)
        }
        return unique.filter { root in !unique.contains { $0 != root && root.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
    }

    /// Nur lexikalisch: kein `standardizedFileURL`, das `/private` abschneidet und den Pfad vom Dateisystem löst.
    private static func lexicallyStandardized(_ path: String) -> String {
        var components: [String] = []
        for part in path.utf8.split(separator: UInt8(ascii: "/")) {
            let name = String(decoding: part, as: UTF8.self)
            if name == ".." { _ = components.popLast() } else if name != "." { components.append(name) }
        }
        return "/" + components.joined(separator: "/")
    }

    func scan() async -> StorageCategoryReport {
        let existing = normalizedRoots.filter { FileIdentity.of($0)?.type == .directory }
        let found = existing.flatMap { root in
            artifacts(in: root, depth: 0).map { (path: $0.0, title: String($0.0.dropFirst(root.count + 1)), identity: $0.1) }
        }
        let sizes = await ConcurrentMeasurement.sizes(of: found.map(\.path), measurer: measurer)
        let items = zip(found, sizes).map { artifact, size in
            StorageItem(id: artifact.path, title: artifact.title, path: artifact.path, size: size, removal: .trash,
                        isPreselected: false, identity: artifact.identity)
        }
        return StorageCategoryReport(category: category, status: existing.isEmpty ? .notInstalled : .available, items: items)
    }

    private func artifacts(in directory: String, depth: Int) -> [(String, FileIdentity)] {
        guard !Task.isCancelled, depth <= Self.maximumDepth,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var found: [(String, FileIdentity)] = []
        let candidates = Self.artifacts.sorted(by: { $0.key < $1.key }).filter { names.contains($0.key) && names.contains($0.value) }
        if !candidates.isEmpty, isStale(directory, names) {
            for (artifact, _) in candidates {
                let path = directory + "/" + artifact
                if let identity = FileIdentity.of(path), identity.type == .directory { found.append((path, identity)) }
            }
        }
        for name in names.sorted() where !RawPath.isHidden(name) && Self.artifacts[name] == nil {
            let child = directory + "/" + name
            guard FileIdentity.of(child)?.type == .directory else { continue }
            found += artifacts(in: child, depth: depth + 1)
        }
        return found
    }

    /// Das Projekt ist unberührt: kein Eintrag außer den Artefakten, kein Git-Marker, kein Artefakt-Ordner samt direkten
    /// Einträgen und kein tieferer Eintrag ist jünger als die Altersgrenze. Die billigen Prüfungen kommen zuerst, der
    /// Tiefenlauf zuletzt; `allSatisfy` bricht früh ab.
    private func isStale(_ directory: String, _ names: [String]) -> Bool {
        let limit = now().addingTimeInterval(-Double(minimumAgeDays) * 86_400)
        let projectEntries = names.filter { Self.artifacts[$0] == nil }.map { directory + "/" + $0 }
        let artifactFolders = names.filter { Self.artifacts[$0] != nil }.map { directory + "/" + $0 }
        return (projectEntries + Self.gitMarkers.map { directory + "/" + $0 }).allSatisfy { isOlder($0, than: limit) }
            && artifactFolders.allSatisfy { folder in
                isOlder(folder, than: limit) && entries(of: folder).allSatisfy { isOlder($0, than: limit) }
            }
            && deepEntriesAreOlder(below: projectEntries, than: limit)
    }

    /// Tiefe Änderungen (#220): Läuft durch die Unterordner von `folders`, ohne Symlinks, versteckte Ordner oder
    /// Artefakte zu betreten, und liest höchstens `deepEntryBudget` Änderungsdaten. Reicht das Budget nicht oder wird
    /// abgebrochen, gilt das Projekt im Zweifel als benutzt; unlesbare Ordner bleiben außen vor.
    private func deepEntriesAreOlder(below folders: [String], than limit: Date) -> Bool {
        var pending = folders.filter { isDescendable($0, status: FileType.linkStatus(of: $0)) }
        var budget = deepEntryBudget
        while let folder = pending.popLast() {
            guard !Task.isCancelled else { return false }
            for child in entries(of: folder) {
                budget -= 1
                guard budget >= 0 else { return false }
                let status = FileType.linkStatus(of: child)
                guard status.map({ Self.modificationDate(of: $0) < limit }) ?? true else { return false }
                if isDescendable(child, status: status) { pending.append(child) }
            }
        }
        return true
    }

    /// Ordner (kein Symlink), weder versteckt noch Artefakt.
    private func isDescendable(_ path: String, status: stat?) -> Bool {
        let name = (path as NSString).lastPathComponent
        return status.map(FileType.isDirectory) == true && !RawPath.isHidden(name) && Self.artifacts[name] == nil
    }

    private func entries(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { folder + "/" + $0 }
    }

    /// Änderungsdatum des Eintrags selbst (`lstat`, Symlinks nicht verfolgt); ohne lesbares Datum zählt er als alt.
    private func isOlder(_ path: String, than limit: Date) -> Bool {
        FileType.linkStatus(of: path).map { Self.modificationDate(of: $0) < limit } ?? true
    }

    private static func modificationDate(of status: stat) -> Date {
        Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9)
    }
}
