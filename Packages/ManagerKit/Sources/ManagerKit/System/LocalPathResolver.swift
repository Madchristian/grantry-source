import Darwin
import Foundation

/// Resolves one component at a time, checking the cached mount table before *any* metadata access.
/// `realpath`, URL standardization and `lstat` of a whole path can follow a parent symlink onto a
/// remote filesystem. Never use those as a preflight for this check. No asynchronous timeout or
/// abandoned work: remote/unknown origins are rejected without entering their filesystem.
/// Like other scan preflights, this assumes mounts and parent directories are not concurrently replaced.
enum LocalPathResolver {
    enum Entry {
        case directory, symbolicLink(String), regularFile(Int), other, missing, unavailable
    }

    struct Target {
        let path: String
        let entry: Entry
    }

    /// `nil` means unknown or non-local, including unreadable links and bounded-out link chains.
    /// Missing local files remain distinguishable from an unavailable volume.
    /// `onNetworkVolume` meldet das abgewiesene Netz-Volume für Hinweise, ohne weitere Dateizugriffe.
    static func resolve(
        _ path: String, volumes: [MountedVolume], onNetworkVolume: (MountedVolume) -> Void = { _ in },
        entry: (String) -> Entry = entry(at:)
    ) -> Target? {
        func permitsAccess(to path: String) -> Bool {
            Self.permitsAccess(to: path, volumes: volumes, onNetworkVolume: onNetworkVolume)
        }
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < Int(PATH_MAX),
              permitsAccess(to: path) else { return nil }
        var pending = Array(path.split(separator: "/").map(String.init).reversed())
        var components: [String] = []
        var links = 0
        var last: Entry = .directory
        var steps = 0
        while let component = pending.popLast() {
            steps += 1
            guard steps <= 1024 else { return nil }
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            let candidate = "/" + (components + [component]).joined(separator: "/")
            guard permitsAccess(to: candidate) else { return nil }
            last = entry(candidate)
            switch last {
            case .symbolicLink(let destination):
                links += 1
                guard links < 40, !destination.isEmpty, !destination.contains("\0"),
                      destination.utf8.count < Int(PATH_MAX) else { return nil }
                // Check the whole link destination too, before reading even its local parents.
                let absolute = destination.hasPrefix("/") ? destination
                    : "/" + (components + [destination]).joined(separator: "/")
                guard permitsAccess(to: absolute) else { return nil }
                if destination.hasPrefix("/") { components.removeAll() }
                pending.append(contentsOf: destination.split(separator: "/").map(String.init).reversed())
            case .unavailable:
                return nil
            case .missing:
                return Target(path: path, entry: .missing)
            default:
                components.append(component)
                if !pending.isEmpty, case .directory = last { continue }
                if !pending.isEmpty { return Target(path: path, entry: .missing) }
            }
        }
        return Target(path: "/" + components.joined(separator: "/"), entry: last)
    }

    static func entry(at path: String) -> Entry {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable
        }
        if FileType.isSymbolicLink(info) {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return .unavailable }
            return .symbolicLink(destination)
        }
        if FileType.isDirectory(info) { return .directory }
        if FileType.isRegularFile(info) { return .regularFile(Int(info.st_size)) }
        return .other
    }

    /// Pure string operations only. Case variants are treated conservatively even on case-sensitive disks.
    /// The data-volume alias must match the same autofs/network mounts as its firmlink spelling.
    private static func permitsAccess(
        to path: String, volumes: [MountedVolume], onNetworkVolume: (MountedVolume) -> Void
    ) -> Bool {
        func mountSpelling(_ path: String) -> String {
            let path = "/" + path.split(separator: "/").joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            let prefix = MountedVolume.dataVolumePrefix.lowercased()
            return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
        }
        let path = mountSpelling(path)
        let mounts = volumes.map { MountedVolume(path: mountSpelling($0.path), isLocal: $0.isLocal) }
        guard let volume = MountedVolume.containing(path, in: mounts) else { return false }
        // Equal mount spellings with conflicting locality are unknown, never evidence for safe I/O.
        if let network = volumes.first(where: { mountSpelling($0.path) == volume.path && !$0.isLocal }) {
            onNetworkVolume(network)
            return false
        }
        let volumesPath = path.replacingOccurrences(of: "/volumes/", with: "/Volumes/", options: .anchored)
        if let mountPoint = MountedVolume.volumesMountPoint(of: volumesPath), volume.path.count < mountPoint.count { return false }
        return true
    }
}
