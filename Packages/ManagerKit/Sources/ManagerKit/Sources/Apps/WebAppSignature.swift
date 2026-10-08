import Foundation

/// Erkennt Web-Apps (PWAs) an ihrer `Info.plist` – nur ein Hinweis, kein Beleg: Jeder kann diese Werte setzen. Ob das
/// Bundle eigenen Code mitbringt, prüft `AppOriginDetector` getrennt.
enum WebAppSignature {
    /// Bundle-ID der Vorlage, aus der Safari Web-Apps erzeugt (`LSTemplateApplicationParameters`).
    static let safariTemplateBundleID = "com.apple.Safari.WebApp"

    /// Präfixe der Bundle-IDs von Chromium-App-Shims (`com.google.Chrome.app.<Erweiterungs-ID>`).
    static let chromiumPrefixes: [(prefix: String, browser: WebAppBrowser)] = [
        ("com.google.Chrome.app.", .chrome),
        ("com.microsoft.edgemac.app.", .edge),
        ("com.brave.Browser.app.", .brave),
    ]

    static func browser(bundleID: String?, info: [String: Any]) -> WebAppBrowser? {
        if isSafariTemplate(info) { return .safari }
        guard let bundleID else { return nil }
        return chromiumPrefixes.first { bundleID.hasPrefix($0.prefix) && bundleID.count > $0.prefix.count }?.browser
    }

    private static func isSafariTemplate(_ info: [String: Any]) -> Bool {
        let parameters = info["LSTemplateApplicationParameters"] as? [String: Any]
        return info["LSTemplateApplication"] as? Bool == true
            && parameters?["CFBundleIdentifier"] as? String == safariTemplateBundleID
    }
}
