import Foundation

/// Herkunft einer App (Spec v3 §2) in fester Reihenfolge: Homebrew-Cask → App Store → Apple → Web-App → direkt.
///
/// App Store heißt: App-Store-Signatur, oder Apple-Signatur mit Store-Beleg (`hasAppStoreEvidence`) – Apple-Apps aus dem
/// App Store (Keynote, Xcode) sind mit `anchor apple` signiert. Ein Beleg allein zählt nicht (Review N3): Er lässt sich
/// in jedes Bundle legen, auch in ein ad hoc signiertes.
///
/// Ohne Signaturergebnis (`.unknown`: Zeitüberschreitung, beschädigte Signatur) und ohne anderen Beleg ist die Herkunft
/// `.unverified` – der Ort entscheidet nicht (Review M2): `/Applications/Xcode-helper.app` mit kaputter Signatur ist
/// keine Apple-App. Der Scan schreibt stattdessen die letzte bekannte Herkunft fort (`Snapshot.carryingForwardAppState`).
///
/// Web-App heißt: ad hoc signiert oder unsigniert und laut `Info.plist` von einem Browser angelegt (`WebAppSignature`).
/// Eine Safari-Web-App zählt nur ohne eigenes Programm (kein Programmordner) – bei jedem Scan neu geprüft, nicht aus dem
/// Bundle-Cache, denn ein nachträglich hineingelegtes Programm ändert das Bundle-Verzeichnis nicht.
enum AppOriginDetector {
    static func origin(ofBundleAt path: String, info: AppBundleInfo, signing: SigningInfo, casks: HomebrewCaskIndex) -> AppOrigin {
        if let cask = casks.cask(forAppAt: path) { return .homebrew(cask: cask) }
        switch signing.kind {
        case .appStore: return .appStore
        case .apple: return hasAppStoreEvidence(atBundle: path, info: info) ? .appStore : .apple
        case .unknown: return .unverified
        case .adHoc, .unsigned: return webAppBrowser(ofBundleAt: path, info: info).map { .webApp(browser: $0) } ?? .direct
        case .developerID, .development: return .direct
        }
    }

    private static func webAppBrowser(ofBundleAt path: String, info: AppBundleInfo) -> WebAppBrowser? {
        guard let browser = info.webAppBrowser else { return nil }
        if browser.bundlesOwnCode { return browser }
        return hasExecutableDirectory(atBundle: path) ? nil : browser
    }

    /// `Contents/MacOS` (bzw. das Bundle selbst bei flachem Aufbau) ist vorhanden – auch als Symlink. Nur `lstat`.
    private static func hasExecutableDirectory(atBundle path: String) -> Bool {
        FileType.exists(atPath: BundleLayout(path: path).executableDirectory)
    }

    /// `Contents/_MASReceipt/receipt` (macOS-App) bzw. `Wrapper/iTunesMetadata.plist` (iOS-App im Wrapper), jeweils als
    /// reguläre Datei – ein Symlink belegt nichts. Geprüft wird nur per `lstat`, geöffnet wird nichts.
    static func hasAppStoreEvidence(atBundle path: String, info: AppBundleInfo) -> Bool {
        let evidence = info.wrappedBundlePath == nil
            ? path + "/Contents/_MASReceipt/receipt"
            : path + "/Wrapper/iTunesMetadata.plist"
        return FileType.isPlainRegularFile(atPath: evidence)
    }
}
