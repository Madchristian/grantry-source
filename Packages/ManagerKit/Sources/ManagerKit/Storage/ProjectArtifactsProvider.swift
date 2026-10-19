import Foundation

/// `.build` (neben `Package.swift`) und `node_modules` (neben `package.json`) in Projekten unter den Code-Wurzeln,
/// höchstens `maximumDepth` Ordner tief, die seit `minimumAgeDays` unberührt sind: weder die übrigen Einträge des
/// Projekts noch die Artefakt-Ordner samt ihren direkten Einträgen sind jünger (Builds und `npm install` schreiben
/// dort, ohne die Einträge des Projekts anzufassen). Folgt keinen Symlinks, betritt weder versteckte Ordner noch
/// gefundene Artefakte. Risiko „mittel“: Papierkorb, nie vorausgewählt. Größen begrenzt parallel.
struct ProjectArtifactsProvider: StorageCategoryProvider {
    static let maximumDepth = 4
    /// Artefakt-Ordner → Manifest, das ein Projekt belegt.
    static let artifacts = [".build": "Package.swift", "node_modules": "package.json"]

    let roots: [String]
    let minimumAgeDays: Int
    var now: @Sendable () -> Date = { Date() }
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

    /// Das Projekt ist unberührt: kein Eintrag außer den Artefakten, kein Artefakt-Ordner und kein direkter Eintrag
    /// darin ist jünger als die Altersgrenze. Die billigen Prüfungen (Projekt) kommen zuerst; `allSatisfy` bricht früh ab.
    private func isStale(_ directory: String, _ names: [String]) -> Bool {
        let limit = now().addingTimeInterval(-Double(minimumAgeDays) * 86_400)
        let projectEntries = names.filter { Self.artifacts[$0] == nil }
        let artifactFolders = names.filter { Self.artifacts[$0] != nil }.map { directory + "/" + $0 }
        return projectEntries.allSatisfy { isOlder(directory + "/" + $0, than: limit) }
            && artifactFolders.allSatisfy { folder in
                isOlder(folder, than: limit) && entries(of: folder).allSatisfy { isOlder($0, than: limit) }
            }
    }

    private func entries(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { folder + "/" + $0 }
    }

    /// Ohne lesbares Änderungsdatum zählt der Eintrag als alt.
    private func isOlder(_ path: String, than limit: Date) -> Bool {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return modified.map { $0 < limit } ?? true
    }
}
