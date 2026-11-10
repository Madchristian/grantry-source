import GrantryShared

/// Erkennt Apple-eigene Kernel-Erweiterungen: Kennung `com.apple.*` (bzw. der Kern `__kernel__`) **und** ein Beleg für
/// Apple als Urheber. Ein fremder Kext mit irreführender `com.apple.`-Kennung bleibt so sichtbar.
///
/// Belege, ohne Signaturprüfung: Bestandteil des Kerns (`OSKernelResource`) oder ein Pfad auf dem versiegelten
/// Systemvolume (`/System/Library/Extensions`, `/System/KernelKit`) – Apple siegelt es, ein geänderter Inhalt startet
/// nicht. Andere Pfade prüft `SigningInspecting` auf eine Apple-Signatur. So prüft ein üblicher Mac keinen der rund
/// 270 geladenen Apple-Kexts einzeln.
///
/// **Grenze:** Der Rückfall `kmutil showloaded` nennt keinen Pfad. Dort gilt `com.apple.*` ohne Pfad als Apple; der
/// Rückfall greift nur, wenn die IOKit-Abfrage scheitert. Installierte Kexts in `/Library/Extensions` prüft die Quelle
/// unabhängig davon mit Pfad und Signatur.
struct AppleKernelExtensionFilter: Sendable {
    static let kernelIdentifier = "__kernel__"
    static let sealedDirectories = ["/System/Library/Extensions/", "/System/KernelKit/"]

    let signing: any SigningInspecting

    func isApple(_ record: LoadedKernelExtensionRecord) -> Bool {
        isApple(bundleID: record.bundleID, path: record.path, isKernelResource: record.isKernelResource)
    }

    func isApple(_ installed: KernelExtension) -> Bool {
        isApple(bundleID: installed.bundleID, path: installed.path, isKernelResource: false)
    }

    private func isApple(bundleID: String, path: String?, isKernelResource: Bool) -> Bool {
        guard AppleIdentifier.matches(bundleID) || bundleID == Self.kernelIdentifier else { return false }
        if isKernelResource { return true }
        guard let path else { return AppleIdentifier.matches(bundleID) }
        if Self.isOnSealedVolume(path) { return true }
        return signing.inspect(path: path).isAppleSigned
    }

    /// Absoluter Pfad ohne `..` unter einem der versiegelten Ordner.
    private static func isOnSealedVolume(_ path: String) -> Bool {
        guard !path.split(separator: "/").contains("..") else { return false }
        return sealedDirectories.contains { path.hasPrefix($0) }
    }
}
