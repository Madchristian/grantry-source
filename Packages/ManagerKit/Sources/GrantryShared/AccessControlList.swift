import Darwin
import Foundation

/// macOS-ACLs (`ACL_TYPE_EXTENDED`) an eigenen Dateien und Ordnern. Modusbits allein machen nichts privat: Ein von einem
/// Vorfahren geerbter Allow-Eintrag gewährt anderen Zugriff trotz `0700`/`0600`. Deny-Einträge gewähren nichts.
public enum AccessControlList {
    /// Rechte, mit denen ein Eintrag Datei oder Ordner verändern, löschen oder umbenennen, darin Einträge anlegen oder
    /// entfernen oder Rechte und Eigentümer ändern kann. `ACL_WRITE_DATA`/`ACL_APPEND_DATA` sind bei Ordnern
    /// `ACL_ADD_FILE`/`ACL_ADD_SUBDIRECTORY`.
    private static let modifyingPermissions: [acl_perm_t] = [
        ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
        ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
    ]

    /// Ob die ACL von `path` (ohne Symlink-Auflösung) mindestens einen Allow-Eintrag hat. Ohne ACL `false`; lässt sie
    /// sich nicht lesen, `true` (fail-closed).
    public static func grantsAccess(atPath path: String) -> Bool {
        anyAllowEntry(in: acl_get_link_np(path, ACL_TYPE_EXTENDED)) { _ in true }
    }

    /// Wie `grantsAccess(atPath:)` für einen geöffneten Deskriptor.
    public static func grantsAccess(descriptor: Int32) -> Bool {
        anyAllowEntry(in: acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)) { _ in true }
    }

    /// Ob die ACL am Deskriptor einem anderen Prinzipal als dem Benutzer `owner` (oder root) Änderungsrechte gewährt
    /// (`modifyingPermissions`) – auch über eine Gruppe, der Benutzer angehören können. Deny-Einträge wie das übliche
    /// `group:everyone deny delete` zählen nicht. Ohne ACL `false`; lässt sie oder ein Eintrag sich nicht lesen, `true`
    /// (fail-closed).
    public static func grantsModification(toOthersThan owner: uid_t, descriptor: Int32) -> Bool {
        anyAllowEntry(in: acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)) { entry in
            guard let principal = userID(of: entry) else { return modifies(entry) }
            return principal != owner && principal != 0 && modifies(entry)
        }
    }

    /// Entfernt die ACL von `path` (ohne Symlink-Auflösung); `false` mit `errno`, wenn das misslingt. Ein Dateisystem
    /// ohne ACLs hat nichts zu entfernen.
    @discardableResult
    public static func remove(atPath path: String) -> Bool {
        withEmptyACL { acl_set_link_np(path, ACL_TYPE_EXTENDED, $0) }
    }

    /// Wie `remove(atPath:)` für einen geöffneten Deskriptor – vor dem ersten Schreiben, damit nie Klartext unter einer
    /// geerbten ACL steht.
    @discardableResult
    public static func remove(from descriptor: Int32) -> Bool {
        withEmptyACL { acl_set_fd_np(descriptor, $0, ACL_TYPE_EXTENDED) }
    }

    /// Ob ein Allow-Eintrag von `acl` `matches` erfüllt. `acl`: Ergebnis von `acl_get_*`; `nil` mit `ENOENT` heißt
    /// „keine ACL“, mit `ENOTSUP` „Dateisystem ohne ACLs“ – jeder andere Lesefehler zählt als Treffer (fail-closed).
    private static func anyAllowEntry(in acl: acl_t?, matching matches: (acl_entry_t) -> Bool) -> Bool {
        guard let acl else { return errno != ENOENT && errno != ENOTSUP }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let current = entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(current, &tag) == 0 else { return true }
            if tag == ACL_EXTENDED_ALLOW, matches(current) { return true }
        }
        return false
    }

    /// Ob `entry` eines der `modifyingPermissions` enthält; ist der Rechtesatz nicht lesbar, `true`.
    private static func modifies(_ entry: acl_entry_t) -> Bool {
        var permissions: acl_permset_t?
        guard acl_get_permset(entry, &permissions) == 0, let permissions else { return true }
        return modifyingPermissions.contains { acl_get_perm_np(permissions, $0) != 0 }
    }

    /// Benutzer-ID des Prinzipals von `entry`; `nil` für Gruppen und nicht auflösbare Prinzipale.
    private static func userID(of entry: acl_entry_t) -> uid_t? {
        guard let qualifier = acl_get_qualifier(entry) else { return nil }
        defer { acl_free(qualifier) }
        var id = id_t()
        var type: Int32 = -1
        guard mbr_uuid_to_id(qualifier.assumingMemoryBound(to: UInt8.self), &id, &type) == 0, type == ID_TYPE_UID else {
            return nil
        }
        return id
    }

    /// Setzt per `apply` eine leere ACL – das entfernt die vorhandene.
    private static func withEmptyACL(_ apply: (acl_t) -> Int32) -> Bool {
        guard let empty = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        return apply(empty) == 0 || errno == ENOTSUP
    }
}
