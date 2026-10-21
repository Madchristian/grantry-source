import Darwin
import Foundation
import Security

/// Vorprüfung unmittelbar vor dem CLI-Aufräumen, keine Sandbox und kein TCC-Disclaim.
/// Akzeptiert root und den angemeldeten Benutzer als Eigentümer; fremde Schreibrechte blockieren den Start.
struct CleanupToolValidator: Sendable {
    struct Rejection: LocalizedError {
        let path: String
        var errorDescription: String? { "Werkzeug oder Pfad nicht vertrauenswürdig: \(path)" }
    }

    func validate(_ executable: String) throws {
        let volumes = MountedVolume.current()
        var rejected: String?
        // LocalPathResolver prüft auch die ursprüngliche Symlink-Kette und verweigert entfernte Volumes.
        guard trustedEntry("/"),
              let target = LocalPathResolver.resolve(executable, volumes: volumes, entry: { path in
                  guard trustedEntry(path) else {
                      rejected = path
                      return .unavailable
                  }
                  return LocalPathResolver.entry(at: path)
              }), case .regularFile = target.entry,
              FileManager.default.isExecutableFile(atPath: target.path) else {
            throw Rejection(path: rejected ?? executable)
        }
        try validateSignature(target.path)
    }

    private func trustedEntry(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0 || info.st_uid == getuid() else { return false }
        // Symlink-Modi sind auf macOS immer 777; relevant sind Besitzer, Eltern und das aufgelöste Ziel.
        if FileType.isSymbolicLink(info) { return true }
        // root-eigene Sticky-Verzeichnisse erlauben kein Ersetzen fremder Einträge (z. B. /private/tmp).
        let stickyRoot = FileType.isDirectory(info) && info.st_uid == 0 && info.st_mode & S_ISVTX != 0
        let administrativeGroup = info.st_gid == 0 || info.st_gid == 80 // wheel / admin
        guard stickyRoot || (info.st_mode & S_IWOTH == 0 &&
                             (info.st_mode & S_IWGRP == 0 || administrativeGroup)) else { return false }
        return !hasWriteACL(path)
    }

    private func hasWriteACL(_ path: String) -> Bool {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var index = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, index, &entry) == 0 {
            index = Int32(ACL_NEXT_ENTRY.rawValue)
            guard let entry else { return true }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { return true }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else { return true }
            let writes: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                                       ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
            if writes.contains(where: { acl_get_perm_np(permissions, $0) != 0 }) { return true }
        }
        return errno != EINVAL && errno != ENOENT
    }

    /// Skripte/unsignierte Homebrew-Werkzeuge bleiben nutzbar; vorhandene ungültige Signaturen werden abgewiesen.
    /// Eine gültige Ad-hoc-Signatur beweist Integrität, keine vertrauenswürdige Herausgeberidentität.
    private func validateSignature(_ path: String) throws {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        if created == errSecCSUnsigned { return }
        guard created == errSecSuccess, let code else { throw Rejection(path: path) }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        guard status == errSecSuccess || status == errSecCSUnsigned else { throw Rejection(path: path) }
    }
}
