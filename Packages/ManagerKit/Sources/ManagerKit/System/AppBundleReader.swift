import Foundation

/// Metadaten eines App-Bundles (Spec v3 §2).
struct AppBundleInfo: Equatable, Sendable {
    let bundleID: String?
    let name: String
    let shortVersion: String?
    let buildVersion: String?
    /// Hauptprogramm (`CFBundleExecutable`, sonst der Bundle-Name); `nil`, wenn es aus dem Bundle hinauszeigen könnte.
    let executablePath: String?
    /// Inneres Bundle einer iOS-App im Wrapper (`Wrapper/<Name>.app`), sonst `nil`.
    let wrappedBundlePath: String?
    /// Browser, dessen Web-App das Bundle laut `Info.plist` ist (`WebAppSignature`); noch ungeprüft, ob es eigenen Code
    /// mitbringt (`AppOriginDetector`).
    var webAppBrowser: WebAppBrowser? = nil
}

/// Liest `AppBundleInfo` ohne `Bundle` (prozessweiter Cache), ohne Launch Services und ohne Blockieren: `Info.plist`
/// nur als reguläre Datei (`BundleLayout.info`), den Namen über `names` (`BundleNameReader`).
enum AppBundleReader {
    /// `nil`, wenn keine lesbare `Info.plist` vorliegt (fehlt, keine reguläre Datei, zu groß, kaputt).
    static func read(bundleAt path: String, names: any AppNameReading = BundleNameReader()) -> AppBundleInfo? {
        let wrapped = wrappedBundle(of: path)
        let layout = BundleLayout(path: wrapped ?? path)
        let info = layout.info
        guard !info.isEmpty else { return nil }
        return AppBundleInfo(
            bundleID: nonEmpty(info["CFBundleIdentifier"]),
            name: names.name(ofBundleAt: path, info: info),
            shortVersion: nonEmpty(info["CFBundleShortVersionString"]),
            buildVersion: nonEmpty(info["CFBundleVersion"]),
            executablePath: layout.executableName(in: info).flatMap(layout.executablePath(named:)),
            wrappedBundlePath: wrapped,
            webAppBrowser: WebAppSignature.browser(bundleID: nonEmpty(info["CFBundleIdentifier"]), info: info)
        )
    }

    /// Inneres Bundle eines iOS-App-Wrappers (`WrapperLayout.innerBundle`).
    static func wrappedBundle(of path: String) -> String? {
        WrapperLayout(path: path)?.innerBundle
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
