import Darwin
import Darwin.membership

/// Prüft die Mitgliedschaft in der Gruppe `admin` über Directory Services (inkl. verschachtelter Gruppen).
public enum AdminMembership {
    /// `true`, wenn `uid` Mitglied der Gruppe `admin` ist. Fehler bei der Auflösung gelten als „nein“.
    public static func isAdministrator(_ uid: uid_t) -> Bool {
        guard let group = getgrnam("admin") else { return false }
        var userUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var groupUUID = userUUID
        guard mbr_uid_to_uuid(uid, &userUUID) == 0,
              mbr_gid_to_uuid(group.pointee.gr_gid, &groupUUID) == 0 else { return false }
        var isMember: Int32 = 0
        guard mbr_check_membership(&userUUID, &groupUUID, &isMember) == 0 else { return false }
        return isMember != 0
    }
}
