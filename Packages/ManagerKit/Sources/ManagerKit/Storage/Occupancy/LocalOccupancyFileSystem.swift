import Darwin

/// Das echte Dateisystem für den Belegungsscanner.
///
/// Die Wurzel löst `LocalPathResolver` auf (Mount-Tabelle vor jedem Zugriff, Netzlaufwerke abgewiesen), danach bestätigt
/// `DirectoryChainGuard` die Kette ab `/` deskriptorgebunden ohne Symlinks. Ordner werden mit `O_NOFOLLOW_ANY` geöffnet
/// – ein Symlink irgendwo im Pfad wird nie verfolgt – und am geöffneten Deskriptor mit der Identität aus dem
/// Elternordner verglichen. Einträge liest `fstatat` relativ zu diesem Deskriptor; keine Datei wird geöffnet, FIFOs und
/// Geräte blockieren also nicht. Einhängepunkte unter der Wurzel erkennt die Mount-Tabelle ohne `stat` auf das fremde
/// Volume. Größen nach derselben Regel wie `FileSizeCalculator` (allozierte Blöcke).
struct LocalOccupancyFileSystem: OccupancyFileSystem {
    /// Abbruch wird alle so viele Einträge eines Ordners geprüft (wie `FileSizeCalculator.checkInterval`).
    static let checkInterval = FileSizeCalculator.checkInterval

    private let volumes: @Sendable () -> [MountedVolume]

    init(volumes: @escaping @Sendable () -> [MountedVolume] = MountedVolume.current) {
        self.volumes = volumes
    }

    func root(at path: String) throws(OccupancyScanError) -> OccupancyRoot {
        let volumes = volumes()
        var isNetwork = false
        guard let target = LocalPathResolver.resolve(path, volumes: volumes, onNetworkVolume: { _ in isNetwork = true }) else {
            throw isNetwork ? .networkVolume : .unavailable
        }
        guard case .directory = target.entry, let components = RawPath.components(of: target.path) else { throw .unavailable }
        // `/` und jeder Präfix bis zur Wurzel; `trustedFrom` hinter der Kette: nur Identitäten, keine Rechte prüfen.
        let chain = RawPath.prefixes(of: components).compactMap(FileIdentity.of)
        guard chain.count == components.count + 1,
              case .allowed(let identity) = DirectoryChainGuard.inspect(components, chain: chain, trustedFrom: chain.count),
              let status = FileType.linkStatus(of: target.path), FileIdentity(status) == identity
        else { throw .unavailable }
        // Die Mount-Tabelle schreibt Einhängepunkte auf dem Datenvolume ohne dessen Präfix (`MountedVolume`); unter einer
        // Wurzel in dessen Schreibweise (ganzer Datenträger) liegen sie mit Präfix.
        let spellings = volumes.flatMap { volume in
            volume.path == "/" || volume.path.hasPrefix(MountedVolume.dataVolumePrefix) ? [volume]
                : [volume, MountedVolume(path: MountedVolume.dataVolumePrefix + volume.path, isLocal: volume.isLocal)]
        }
        let prefix = target.path + "/"
        let mountPoints = Dictionary(
            spellings.filter { $0.path.hasPrefix(prefix) }.map { ($0.path, $0.isLocal) },
            uniquingKeysWith: { first, second in first && second }
        )
        return OccupancyRoot(path: target.path, identity: identity, modification: status.st_mtimespec.nanoseconds,
                             mountPoints: mountPoints)
    }

    func readDirectory(
        at path: String, expected: FileIdentity, in root: OccupancyRoot, isCancelled: () -> Bool,
        visit: (OccupancyEntry) -> Void
    ) -> OccupancyReadOutcome {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { return Self.outcome(ofFailedOpen: errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, FileIdentity(info) == expected else {
            close(descriptor)
            return .uncaptured(.changed)
        }
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            return .uncaptured(.failed)
        }
        defer { closedir(directory) }
        var isComplete = true, count = 0
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { isComplete = false }
                break
            }
            count += 1
            if count.isMultiple(of: Self.checkInterval), isCancelled() { return .cancelled }
            let name = Self.name(of: entry)
            guard name != ".", name != ".." else { continue }
            let type = Int32(entry.pointee.d_type)
            if !root.mountPoints.isEmpty, type == DT_DIR || type == DT_UNKNOWN,
               let isLocal = root.mountPoints[path + "/" + name] {
                visit(.mountPoint(name: name, isLocal: isLocal))
                continue
            }
            var status = stat()
            guard fstatat(dirfd(directory), name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { visit(.unreadable(name: name)) }
                continue
            }
            visit(Self.entry(named: name, status))
        }
        return .read(isComplete: isComplete)
    }

    private static func entry(named name: String, _ status: stat) -> OccupancyEntry {
        let modification = status.st_mtimespec.nanoseconds
        if FileType.isRegularFile(status) {
            return .file(name: name, identity: FileIdentity(status), allocatedBytes: FileSizeCalculator.allocatedBytes(of: status),
                         linkCount: Int(status.st_nlink), modification: modification)
        }
        if FileType.isDirectory(status) {
            return .directory(name: name, identity: FileIdentity(status), modification: modification,
                              isDataless: status.st_flags & UInt32(SF_DATALESS) != 0)
        }
        return .other(name: name, modification: modification)
    }

    private static func outcome(ofFailedOpen code: Int32) -> OccupancyReadOutcome {
        switch code {
        case ENOENT, ENOTDIR: .vanished
        case EACCES, EPERM: .uncaptured(.permissionDenied)
        case ELOOP: .uncaptured(.changed)
        // Ohne Nachladen scheitert ein iCloud-Platzhalter mit EDEADLK (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`).
        case EDEADLK: .cloudOnly
        default: .uncaptured(.failed)
        }
    }

    /// Name ohne Kopie des ganzen `d_name`-Puffers (1 KB je Eintrag).
    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        let length = Int(entry.pointee.d_namlen)
        return withUnsafePointer(to: &entry.pointee.d_name) { name in
            String(decoding: UnsafeRawBufferPointer(start: name, count: length), as: UTF8.self)
        }
    }
}

extension timespec {
    /// Nanosekunden seit 1970.
    var nanoseconds: OccupancyTimestamp {
        OccupancyTimestamp(tv_sec) * 1_000_000_000 + OccupancyTimestamp(tv_nsec)
    }
}
