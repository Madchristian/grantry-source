import Darwin
import GrantryShared

/// Gemeinsame deskriptorgebundene Prüfung für Papierkorb- und Speicherpfade.
enum DirectoryChainGuard {
    /// Ergebnis mit dem geprüften Objekt (für `LeftoverCandidate.identity`).
    enum Inspection: Equatable {
        case allowed(FileIdentity)
        case blocked(String)

        var verdict: RemovalVerdict {
            switch self {
            case .allowed: .allowed
            case .blocked(let reason): .blocked(reason)
            }
        }
    }

    /// Öffnet dieselbe Kette ab `/` relativ zu gebundenen Deskriptoren, ohne Symlinks zu folgen. Ab dem erlaubten
    /// Wurzelort bis einschließlich Elternordner müssen Eigentümer, Modus und ACL vertrauenswürdig sein. Vorfahren
    /// außerhalb dieses Bereichs werden nur auf Identität geprüft (auch Scratch-Wurzeln dürfen unter `/tmp` liegen).
    static func inspect(_ components: [String], chain: [FileIdentity], trustedFrom rootDepth: Int) -> Inspection {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .blocked("Nicht vorhanden") }
        defer { close(descriptor) }
        for depth in 0..<components.count {
            var info = stat()
            guard fstat(descriptor, &info) == 0, FileIdentity(info) == chain[depth] else {
                return .blocked("Eintrag wurde ersetzt")
            }
            if depth >= rootDepth {
                guard hasTrustedDirectoryPermissions(info),
                      !AccessControlList.grantsModification(toOthersThan: geteuid(), descriptor: descriptor) else {
                    return .blocked("Ordner fremd beschreibbar")
                }
            }
            if depth < components.count - 1 {
                let next = openat(descriptor, components[depth], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { return .blocked("Eintrag wurde ersetzt") }
                close(descriptor)
                descriptor = next
            }
        }
        var entry = stat()
        guard fstatat(descriptor, components[components.count - 1], &entry, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(entry) == chain.last else { return .blocked("Eintrag wurde ersetzt") }
        return .allowed(FileIdentity(entry))
    }

    /// Nur root oder der ausführende Benutzer dürfen Eigentümer sein; Other-Write ist immer gesperrt. Gruppenschreibrecht
    /// ist ausschließlich bei root-eigenen Ordnern mit macOS-Systemgruppe `wheel` (0) oder `admin` (80) erlaubt:
    /// `/Applications` ist regulär `root:admin 0775`, und diese Gruppen liegen bereits innerhalb der Admin-Vertrauensgrenze.
    static func hasTrustedDirectoryPermissions(_ info: stat) -> Bool {
        guard info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & 0o002 == 0 else { return false }
        return info.st_mode & 0o020 == 0 || (info.st_uid == 0 && (info.st_gid == 0 || info.st_gid == 80))
    }
}
