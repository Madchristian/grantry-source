import Darwin

/// Benutzerkonten für Texte (Dialog des Helpers, Verlauf der App).
public enum UserAccount {
    /// Kurzname laut Benutzerdatenbank (`getpwuid`), sonst die UID als Zahl; einzeilig.
    public static func shortName(of uid: UInt32) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "\(uid)" }
        return DisplayText.singleLine(String(cString: name))
    }
}
