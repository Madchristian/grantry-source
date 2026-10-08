import Foundation

/// Ordnet App-Bundles Homebrew-Casks zu (Spec v3 §2, Plan-Abweichung 1). Belege je `<Caskroom>/<cask>/`:
/// 1. Symlinks `<version>/<Name>.app` → installiertes Bundle (so legt Homebrew jede `app`-Installation an).
/// 2. Ersatzweise `.metadata/INSTALL_RECEIPT.json` → `uninstall_artifacts[].app` (Name, optional `{"target": …}`) im
///    Ordner aus `.metadata/config.json` (`appdir` aus `explicit`, `env`, `default` – in dieser Reihenfolge, wie
///    Homebrew –, sonst `/Applications`).
///
/// `.metadata/<version>/<zeitstempel>/Casks/<cask>.json` ist unter Homebrew 6 leer und wird nicht gelesen. Metadaten
/// liest nur `FileType.contentsOfRegularFile` (keine FIFOs, höchstens `maximumMetadataLength`).
public struct HomebrewCaskIndex: Sendable, Equatable {
    public static let standardCaskrooms = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    public static let empty = HomebrewCaskIndex(keyedCasks: [:])
    static let defaultAppDirectory = "/Applications"
    static let maximumMetadataLength = 1 << 20

    /// Kanonischer Pfad in Kleinschreibung (APFS unterscheidet standardmäßig nicht) → Cask.
    private let casksByKey: [String: String]

    private init(keyedCasks: [String: String]) {
        casksByKey = keyedCasks
    }

    /// Index aus Bundle-Pfad → Cask; die Pfade werden wie bei der Abfrage kanonisiert.
    init(casksByPath: [String: String]) {
        var keyed: [String: String] = [:]
        for (path, cask) in casksByPath {
            if let key = Self.key(path) { keyed[key] = cask }
        }
        self.init(keyedCasks: keyed)
    }

    /// Cask, der das Bundle unter `path` installiert hat.
    public func cask(forAppAt path: String) -> String? {
        Self.key(path).flatMap { casksByKey[$0] }
    }

    /// Liest alle Caskrooms; fehlende Caskrooms zählen als leer. Ein Bundle gehört dem ersten Cask, der es belegt
    /// (Caskrooms in der übergebenen Reihenfolge, Casks alphabetisch, Symlinks vor dem Beleg).
    public static func load(caskrooms: [String] = standardCaskrooms, home: String = NSHomeDirectory()) -> HomebrewCaskIndex {
        var casks: [String: String] = [:]
        for caskroom in caskrooms {
            for cask in visibleDirectories(in: caskroom) {
                let caskPath = caskroom + "/" + cask
                for appPath in linkedApps(inCask: caskPath) + receiptApps(inCask: caskPath, home: home) {
                    if let key = key(appPath), casks[key] == nil { casks[key] = cask }
                }
            }
        }
        return HomebrewCaskIndex(keyedCasks: casks)
    }

    struct AppArtifact: Equatable {
        let source: String
        let target: String?
    }

    /// `app`-Artefakte aus `INSTALL_RECEIPT.json`; ein Objekt mit `target` gilt für den Namen davor.
    static func appArtifacts(inReceipt data: Data) -> [AppArtifact] {
        guard let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifacts = receipt["uninstall_artifacts"] as? [[String: Any]] else { return [] }
        var result: [AppArtifact] = []
        for values in artifacts.compactMap({ $0["app"] as? [Any] }) {
            for value in values {
                if let source = value as? String {
                    result.append(AppArtifact(source: source, target: nil))
                } else if let options = value as? [String: Any], let target = options["target"] as? String,
                          let last = result.popLast() {
                    result.append(AppArtifact(source: last.source, target: target))
                }
            }
        }
        return result
    }

    /// `appdir` aus `config.json`: `explicit` (`--appdir`) vor `env` (`HOMEBREW_CASK_OPTS`) vor `default`; leere
    /// Werte zählen nicht, `~` steht für `home`.
    static func appDirectory(inConfig data: Data, home: String = NSHomeDirectory()) -> String? {
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ["explicit", "env", "default"].lazy
            .compactMap { (config[$0] as? [String: Any])?["appdir"] as? String }
            .first { !$0.isEmpty }
            .map { expandingTilde($0, home: home) }
    }

    /// `~` bzw. `~/…` als Pfad in `home`; anderes unverändert.
    private static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    /// Ziele der `.app`-Symlinks in den Versionsordnern eines Casks.
    private static func linkedApps(inCask cask: String) -> [String] {
        visibleDirectories(in: cask).flatMap { version -> [String] in
            let directory = cask + "/" + version
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names.filter { $0.hasSuffix(".app") }.sorted().compactMap { name in
                let link = directory + "/" + name
                // Nur Symlinks auf Vorhandenes: Ein toter Link (App von Hand gelöscht) belegt nichts.
                guard FileType.linkStatus(of: link).map(FileType.isSymbolicLink) == true, FileType.status(of: link) != nil,
                      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
                return destination.hasPrefix("/") ? destination : directory + "/" + destination
            }
        }
    }

    /// Bundle-Pfade laut `INSTALL_RECEIPT.json` und `config.json`.
    private static func receiptApps(inCask cask: String, home: String) -> [String] {
        let metadata = cask + "/.metadata"
        guard let receipt = metadataFile(metadata + "/INSTALL_RECEIPT.json") else { return [] }
        let appDirectory = metadataFile(metadata + "/config.json").flatMap { appDirectory(inConfig: $0, home: home) }
            ?? defaultAppDirectory
        return appArtifacts(inReceipt: receipt).map { artifact in
            let target = expandingTilde(artifact.target ?? URL(fileURLWithPath: artifact.source).lastPathComponent, home: home)
            return target.hasPrefix("/") ? target : appDirectory + "/" + target
        }
    }

    private static func metadataFile(_ path: String) -> Data? {
        FileType.contentsOfRegularFile(atPath: path, maximumLength: maximumMetadataLength)
    }

    /// Nicht versteckte Unterordner (keine Symlinks), sortiert; `.metadata` fällt als versteckt heraus.
    private static func visibleDirectories(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") && FileType.isPlainDirectory(atPath: path + "/" + $0) }
            .sorted()
    }

    private static func key(_ path: String) -> String? {
        AppleComponent.canonicalPath(path)?.lowercased()
    }
}
