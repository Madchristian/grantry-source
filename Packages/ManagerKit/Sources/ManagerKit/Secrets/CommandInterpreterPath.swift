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
        guard case .contents(let data, _) = RegularFileReader.read(atPath: path, maximumSize: maximumShellSize) else { return nil }
        return ShellIdentity(path: path, size: data.count, digest: SHA256.hash(data: data))
    }

    static func resolve(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let target = FileFingerprint.target(of: path)
        // Bekannte Namen brauchen keinen Inhaltsvergleich; unbekannte Dateien nur bei passender Größe lesen.
        guard !ShellSyntax.isShell(target), let status = FileType.status(of: target), FileType.isRegularFile(status) else {
            return target
        }
        let candidates = systemShells.filter { $0.size == status.st_size }
        guard !candidates.isEmpty,
              case .contents(let data, _) = RegularFileReader.read(atPath: target, maximumSize: maximumShellSize) else { return target }
        let digest = SHA256.hash(data: data)
        return candidates.first { $0.size == data.count && $0.digest == digest }?.path ?? target
    }
}
