import Foundation
import GrantryShared

/// Apple-Kennungen in Eintragsnamen der Reste-Orte, byteweise und ohne Groß-/Kleinschreibung erkannt.
enum AppleEntryName {
    /// `true`, wenn `identifier` mit `com.apple.` beginnt (ohne Groß-/Kleinschreibung).
    static func isApple(_ identifier: String) -> Bool {
        identifier.lowercased().utf8.starts(with: AppleIdentifier.prefix.utf8)
    }

    /// Apple-Kennung (klein) im Eintragsnamen – direkt (`com.apple.Safari.plist`) oder hinter einem bzw. zwei ersten
    /// Bestandteilen (`group.com.apple.notes`, `74J34U3R6X.com.apple.iWork`, `74J34U3R6X.group.com.apple.notes`); sonst
    /// `nil`. Bewusst weit gefasst: Im Zweifel gilt ein Eintrag als Apple-Eintrag.
    static func identifier(in name: String) -> String? {
        var rest = name.lowercased()
        for _ in 0...2 {
            if isApple(rest) { return rest }
            guard let dot = rest.utf8.firstIndex(of: UInt8(ascii: ".")) else { return nil }
            rest = String(decoding: rest.utf8[rest.utf8.index(after: dot)...], as: UTF8.self)
        }
        return nil
    }
}

/// Bundle-IDs und Namen der Apps des versiegelten Systems (`/System/Applications`, CoreServices). Gelesen wird nur
/// `Info.plist`, ohne Blockieren (`BundleLayout.info`) – keine Systemdienste.
struct SystemAppCatalog: Sendable {
    /// Suchumgebung, damit auch Herkunftsprüfungen systemweite Orte wie die Inventur erkennen.
    let layout: LibraryLayout
    /// Bundle-IDs in Kleinschreibung.
    let bundleIDs: Set<String>
    /// Bundle-Namen ohne `.app` und `CFBundleName`.
    let names: Set<String>

    init(bundleIDs: Set<String> = [], names: Set<String> = [], layout: LibraryLayout = .standard) {
        self.layout = layout
        self.bundleIDs = bundleIDs
        self.names = names
    }

    init(layout: LibraryLayout) {
        var bundleIDs: Set<String> = [], names: Set<String> = []
        for root in layout.systemAppRoots {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            where RawPath.hasExtension(entry, "app") && FileType.isPlainDirectory(atPath: root + "/" + entry) {
                let info = BundleLayout(path: root + "/" + entry).info
                if let bundleID = info["CFBundleIdentifier"] as? String { bundleIDs.insert(bundleID.lowercased()) }
                if let name = info["CFBundleName"] as? String { names.insert(name) }
                names.insert(String(entry.dropLast(".app".count)))
            }
        }
        self.init(bundleIDs: bundleIDs, names: names, layout: layout)
    }
}

/// Wer Apple-Kennungen (`com.apple.…`) besitzen darf: nur eine App, die nachweislich von Apple stammt, und nie eine
/// Kopie einer System-App – deren Daten gehören der System-App.
struct AppleAppVerification: Sendable {
    let catalog: SystemAppCatalog

    /// Apple-Signatur (`anchor apple`) oder App-Store-Herkunft mit App-Store-Signatur: Apple signiert jede App aus dem
    /// App Store selbst und vergibt dort keine `com.apple.`-Kennungen an Dritte. Bundle-ID oder Ort allein belegen nichts.
    static func hasAppleProvenance(_ app: InstalledApp) -> Bool {
        app.signing.kind == .apple || (app.origin == .appStore && app.signing.kind == .appStore)
    }

    /// Bundle-ID (klein), wenn `app` eine Apple-Kennung trägt und sie besitzen darf; sonst `nil`.
    func appleOwnerID(of app: InstalledApp) -> String? {
        guard let bundleID = app.bundleID?.lowercased(), AppleEntryName.isApple(bundleID),
              Self.hasAppleProvenance(app), !catalog.bundleIDs.contains(bundleID) else { return nil }
        return bundleID
    }

    /// Darf `app` Einträge nach ihrer Bundle-ID besitzen? Nicht-Apple-Kennungen immer, Apple-Kennungen nur nachweislich.
    func mayOwnEntries(of app: InstalledApp) -> Bool {
        guard let bundleID = app.bundleID else { return false }
        return !AppleEntryName.isApple(bundleID) || appleOwnerID(of: app) != nil
    }
}
