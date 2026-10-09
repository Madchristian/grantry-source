import CryptoKit
import Foundation
import GrantryShared

/// Pfadauflösung nur für die Befehlsmaskierung (#173), keine Signatur-/Vertrauensprüfung.
/// Erkennt Symlinks und bytegleiche Kopien der installierten System-Shells. Keine Suche im PATH:
/// launchd und MCP-Hosts können einen anderen PATH bzw. ein anderes Arbeitsverzeichnis verwenden.
enum CommandInterpreterPath {
    private static let maximumShellSize = 8 * 1024 * 1024
    private struct ShellIdentity: Sendable {
        let path: String
        let size: Int
        let digest: SHA256.Digest
    }
    private static let systemShells: [ShellIdentity] = ["sh", "bash", "zsh", "ksh", "csh", "tcsh"].compactMap { name in
        let path = "/bin/" + name
        guard let target = LocalPathResolver.resolve(path, volumes: MountedVolume.current()),
              case .regularFile = target.entry, let data = FileSystem.local.contents(target.path) else { return nil }
        return ShellIdentity(path: path, size: data.count, digest: SHA256.hash(data: data))
    }

    struct FileSystem {
        typealias Entry = LocalPathResolver.Entry
        let entry: (String) -> Entry
        let contents: (String) -> Data?

        static var local: Self {
            Self(entry: LocalPathResolver.entry, contents: { path in
                guard case .contents(let data, _) = RegularFileReader.read(atPath: path, maximumSize: maximumShellSize) else { return nil }
                return data
            })
        }
    }

    static func resolve(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return resolve(path, volumes: MountedVolume.current(), fileSystem: .local)
    }

    /// Unknown origin is a shell *candidate*, not a claim about the executable's actual identity.
    /// Both metadata and contents are skipped on remote paths, including links in parent directories.
    static func resolve(_ path: String, volumes: [MountedVolume], fileSystem: FileSystem = .local) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        guard let target = LocalPathResolver.resolve(path, volumes: volumes, entry: fileSystem.entry) else { return "/bin/sh" }
        // Known names and non-regular files need no content comparison.
        guard !ShellSyntax.isShell(target.path), case .regularFile(let size) = target.entry else { return target.path }
        let candidates = systemShells.filter { $0.size == size }
        guard !candidates.isEmpty, let data = fileSystem.contents(target.path) else { return target.path }
        let digest = SHA256.hash(data: data)
        return candidates.first { $0.size == data.count && $0.digest == digest }?.path ?? target.path
    }
}
