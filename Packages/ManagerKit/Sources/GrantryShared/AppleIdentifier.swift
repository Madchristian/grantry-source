/// Erkennt Apple-Kennungen (Bundle-IDs, launchd-Labels, TCC-Client-IDs) am Präfix `com.apple.`.
public enum AppleIdentifier {
    public static let prefix = "com.apple."

    /// `true`, wenn `identifier` mit `com.apple.` beginnt.
    public static func matches(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix)
    }
}
