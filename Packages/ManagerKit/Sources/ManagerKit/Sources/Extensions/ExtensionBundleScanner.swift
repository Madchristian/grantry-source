import Darwin
import Foundation
import GrantryShared

/// Kennung, Version und Name eines Erweiterungs-Bundles aus seiner `Contents/Info.plist`.
///
/// Bundle-ID, Version und Name stammen vom Hersteller und sind einzeilig und gekürzt (`ExtensionText`); der Pfad bleibt
/// unverändert, weil er auf das Bundle zeigt.
struct ExtensionBundle: Hashable, Sendable {
    let bundleID: String
    /// `CFBundleShortVersionString`, ersatzweise `CFBundleVersion`.
    let version: String?
    /// `CFBundleName`.
    let name: String?
    let path: String
}

/// Erweiterungs-Bundles eines Ordners (`*.kext`, `*.driver`, `*.systemextension` …): je Bundle die `Contents/Info.plist`,
/// bei flachen Bundles ohne `Contents` (DriverKit `*.dext`) die `Info.plist` im Bundle selbst.
///
/// Synchron und blockierend; Aufrufer lagern ihn aus (`ExtensionWork`). Symlinks werden nicht gefolgt – weder im Pfad
/// des Ordners noch beim Bundle, bei `Contents` oder `Info.plist` –, gelesen werden nur reguläre Dateien bis
/// `maximumPlistSize` (`RegularFileReader`). Ein fehlender Ordner heißt „nichts installiert“; ein vorhandenes, aber nicht
/// auswertbares Bundle steht mit Grund in `unreadable`, damit die Liste nicht als vollständig gilt. Einträge mit anderer
/// Endung (etwa `plugins-info.txt` im DAL-Ordner) gehören nicht dazu.
struct ExtensionBundleScanner: Sendable {
    static let maximumPlistSize = 1 << 20

    static let symlinkText = "Symlink, nicht gefolgt"
    static let symlinkInPathText = "Symlink im Pfad, nicht gefolgt"
    static let notBundleText = "kein Bundle"
    static let missingPlistText = "Info.plist fehlt"
    static let invalidPlistText = "Info.plist ohne Bundle-ID"
    static let notDirectoryText = "kein Ordner"

    static func entryLimitText(_ limit: Int) -> String { "mehr als \(limit) Erweiterungen, Rest nicht gelesen" }

    struct Scan: Hashable, Sendable {
        var bundles: [ExtensionBundle] = []
        var unreadable: [UnreadableExtension] = []
    }

    let directory: String
    /// Endungen samt Punkt, ohne Rücksicht auf Groß- und Kleinschreibung (`.kext`).
    let suffixes: [String]
    let maximumEntries: Int

    func scan() -> Scan {
        var scan = Scan()
        switch Self.directoryState(directory) {
        case .directory: break
        case .missing: return scan
        case .refused(let reason):
            scan.unreadable.append(UnreadableExtension(path: directory, reason: reason))
            return scan
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            scan.unreadable.append(UnreadableExtension(path: directory, reason: RegularFileReader.unreadableText))
            return scan
        }
        let lowercasedSuffixes = suffixes.map { $0.lowercased() }
        let bundles = names.filter { name in lowercasedSuffixes.contains { name.lowercased().hasSuffix($0) } }.sorted()
        for name in bundles.prefix(maximumEntries) {
            let path = (directory as NSString).appendingPathComponent(name)
            switch Self.read(bundleAt: path) {
            case .success(let bundle): scan.bundles.append(bundle)
            case .failure(let failure): scan.unreadable.append(UnreadableExtension(path: path, reason: failure.reason))
            }
        }
        if bundles.count > maximumEntries {
            scan.unreadable.append(UnreadableExtension(path: directory, reason: Self.entryLimitText(maximumEntries)))
        }
        return scan
    }

    private enum DirectoryState {
        /// Ein Ordner ohne Symlink im Pfad.
        case directory
        /// Er oder ein Elternordner fehlt: nichts installiert.
        case missing
        /// Vorhanden, aber nicht gelesen.
        case refused(String)
    }

    private static func directoryState(_ directory: String) -> DirectoryState {
        let components = directory.split(separator: "/", omittingEmptySubsequences: true)
        var path = ""
        for (index, component) in components.enumerated() {
            path += "/" + component
            let isLast = index == components.count - 1
            switch fileType(atPath: path) {
            case .none: return errno == ENOENT || errno == ENOTDIR ? .missing : .refused(RegularFileReader.unreadableText)
            case .some(S_IFLNK): return .refused(isLast ? symlinkText : symlinkInPathText)
            case .some(S_IFDIR): continue
            case .some: return isLast ? .refused(notDirectoryText) : .missing
            }
        }
        return .directory
    }

    private struct Failure: Error {
        let reason: String
    }

    private static func read(bundleAt path: String) -> Result<ExtensionBundle, Failure> {
        switch fileType(atPath: path) {
        case .some(S_IFDIR): break
        case .some(S_IFLNK): return .failure(Failure(reason: symlinkText))
        default: return .failure(Failure(reason: notBundleText))
        }
        let contents = (path as NSString).appendingPathComponent("Contents")
        let plistPath: String
        switch fileType(atPath: contents) {
        // Flaches Bundle ohne `Contents` (DriverKit `*.dext`): Info.plist direkt im Bundle.
        case .none: plistPath = (path as NSString).appendingPathComponent("Info.plist")
        case .some(S_IFLNK): return .failure(Failure(reason: symlinkText))
        default: plistPath = (contents as NSString).appendingPathComponent("Info.plist")
        }
        switch fileType(atPath: plistPath) {
        case .none: return .failure(Failure(reason: missingPlistText))
        case .some(S_IFLNK): return .failure(Failure(reason: symlinkText))
        default: break
        }
        switch RegularFileReader.read(atPath: plistPath, maximumSize: maximumPlistSize) {
        case .missing:
            return .failure(Failure(reason: missingPlistText))
        case .unreadable(let reason):
            return .failure(Failure(reason: reason))
        case .contents(let data, _):
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
                return .failure(Failure(reason: invalidPlistText))
            }
            let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
            return .success(ExtensionBundle(
                bundleID: ExtensionText.identifier(bundleID),
                version: version.map(ExtensionText.version),
                name: (plist["CFBundleName"] as? String).map(ExtensionText.name),
                path: path
            ))
        }
    }

    /// Dateiart (`S_IFDIR`, `S_IFLNK` …) ohne Symlinks zu folgen; `nil`, wenn `lstat` scheitert (`errno` gesetzt).
    private static func fileType(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }
}

/// Liest Erweiterungen nur auf lokalen Volumes: Ein Ordner auf einem Netzlaufwerk (etwa im Netz-Home) könnte den Scan an
/// einem hängenden Server festhalten. Die Einhängepunkte kommen aus `MountedVolume.current()` (`MNT_NOWAIT`, blockiert
/// selbst nicht); ein Pfad ohne bekanntes Volume gilt als nicht prüfbar und wird ebenfalls nicht gelesen.
struct ExtensionVolumeCheck: Sendable {
    static let networkVolumeText = "liegt auf einem Netzlaufwerk, nicht gelesen"
    static let uncheckedVolumeText = "Volume nicht prüfbar, nicht gelesen"

    let volumes: @Sendable () -> [MountedVolume]

    init(volumes: @escaping @Sendable () -> [MountedVolume] = MountedVolume.current) {
        self.volumes = volumes
    }

    /// Die Einhängepunkte einmal je Scan; `refusal(forPath:)` prüft danach jeden Pfad ohne weiteren Systemaufruf.
    func snapshot() -> Snapshot { Snapshot(volumes: volumes()) }

    struct Snapshot: Sendable {
        let volumes: [MountedVolume]

        /// `nil` für einen Pfad auf einem lokalen Volume, sonst der Grund, ihn nicht zu lesen.
        func refusal(forPath path: String) -> String? {
            guard let volume = MountedVolume.containing(path, in: volumes) else { return ExtensionVolumeCheck.uncheckedVolumeText }
            return volume.isLocal ? nil : ExtensionVolumeCheck.networkVolumeText
        }
    }
}
