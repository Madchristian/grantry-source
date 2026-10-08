import Foundation

/// Erkennt Bestandteile von macOS und Apples Entwicklerwerkzeugen – an Signatur, Kennung (`com.apple.`) oder
/// Installationsort. Apple-Komponenten sind nur lesbar und lösen keine Risiko-Befunde aus: Launch Services findet
/// viele von ihnen nicht (Agents, Helfer, XPC-Dienste), und ihre Signatur prüft Apple selbst.
///
/// Herkunft von Code (`hasAppleOrigin`): Ist die Signatur bekannt, zählt ausschließlich sie; der Installationsort ist
/// nur Rückfall, wenn keine Signatur vorliegt (`nil`, `.unknown`). Pfade werden vor dem Vergleich kanonisiert
/// (Symlinks, `..`, doppelte `/`) und ohne Rücksicht auf Groß-/Kleinschreibung verglichen – wie APFS sie auflöst.
///
/// Die Pfad-Erkennung ist kein Schutz gegen Täuschung durch root: Wer Programme unter `/Library/Developer/` oder
/// `/usr/libexec` ablegt, braucht dafür root – das liegt außerhalb des Bedrohungsmodells.
public enum AppleComponent {
    /// Verzeichnisse, die ausschließlich Apple-Software enthalten (versiegeltes System, Xcode-Zusatzkomponenten);
    /// in Kleinschreibung.
    private static let applePrefixes = ["/system/", "/usr/", "/library/apple/", "/library/developer/"]
    /// Vorrangige Ausnahmen: Unter `/usr/` legt Drittsoftware (Homebrew & Co.) nur `/usr/local/` an, und unter
    /// `/System/Volumes/` liegt das beschreibbare Datenvolume (kanonische Pfade wie
    /// `/System/Volumes/Data/Applications/…` oder `/System/Volumes/Data/Users/…`).
    private static let thirdPartyPrefixes = ["/usr/local/", "/system/volumes/"]
    /// Ausnahme davon: Cryptexe im Preboot-Volume (Safari, Teile des Systems; `/Applications/Safari.app` zeigt nach
    /// `/System/Volumes/Preboot/Cryptexes/App/…`) sind versiegelt und nur für das System beschreibbar.
    /// `/System/Volumes/Data/` (Firmlink auf Nutzerdaten) bleibt Drittanbieter.
    private static let sealedVolumePrefixes = ["/system/volumes/preboot/cryptexes/"]
    private static let applications = "/applications/"

    /// `true`, wenn der kanonische `path` unter einem Apple-Verzeichnis liegt oder zu einem Xcode-Bundle in
    /// `/Applications` gehört. Relative Pfade und Kennungen (Bundle-IDs) sind nie Apple-Pfade.
    public static func isApplePath(_ path: String) -> Bool {
        guard let canonical = canonicalPath(path) else { return false }
        let directory = (canonical.hasSuffix("/") ? canonical : canonical + "/").lowercased()
        return isSystemDirectory(directory) || isInsideXcode(directory)
    }

    /// Apple-Herkunft von Code: bei bekannter Signatur nur `isAppleSigned`, sonst (`nil`, `.unknown`) ein Apple-Pfad.
    public static func hasAppleOrigin(signing: SigningInfo?, path: String?) -> Bool {
        if let signing, signing.kind != .unknown { return signing.isAppleSigned }
        return path.map(isApplePath) == true
    }

    /// Nachweislich echte Apple-App – für Ausnahmen von Prüfungen, die Täuschung erkennen sollen (Tiefenprüfung):
    /// Apple-signiert (`anchor apple`), App-Store-signiert mit `com.apple.`-Kennung (der App Store vergibt keine
    /// Apple-Kennungen an Dritte; Keynote, Xcode, Logic) oder ohne Signaturergebnis im versiegelten System
    /// (`isSystemPath`). Eine `com.apple.`-Kennung allein (frei im Info.plist setzbar) oder ein Xcode-ähnlicher Name in
    /// `/Applications` genügen nicht.
    public static func isGenuineApple(_ app: AppIdentity) -> Bool {
        switch app.signing.kind {
        case .apple: true
        case .appStore: app.bundleID.map(AppleIdentifier.matches) == true
        case .unknown: app.path.map(isSystemPath) == true
        default: false
        }
    }

    /// Kanonischer `path` unter einem Apple-Verzeichnis (ohne die Xcode-Ausnahme in `/Applications`, die jeder Benutzer
    /// mit Schreibrecht dort anlegen kann).
    static func isSystemPath(_ path: String) -> Bool {
        guard let canonical = canonicalPath(path) else { return false }
        return isSystemDirectory((canonical.hasSuffix("/") ? canonical : canonical + "/").lowercased())
    }

    /// `directory`: kanonisch, kleingeschrieben, mit abschließendem `/`.
    private static func isSystemDirectory(_ directory: String) -> Bool {
        if sealedVolumePrefixes.contains(where: directory.hasPrefix) { return true }
        return !thirdPartyPrefixes.contains(where: directory.hasPrefix) && applePrefixes.contains(where: directory.hasPrefix)
    }

    /// App von Apple: `com.apple.`-Bundle-ID oder Apple-Herkunft (`hasAppleOrigin`).
    ///
    /// Die Bundle-ID zählt hier ohne Signatur: App-Store-Apps von Apple (Pages, Keynote) sind nicht mit `anchor apple`
    /// signiert. Für launchd-Einträge gilt sie nicht (`contains(_: AutostartItem)`).
    public static func contains(_ app: AppIdentity) -> Bool {
        app.bundleID.map(AppleIdentifier.matches) == true || hasAppleOrigin(signing: app.signing, path: app.path)
    }

    /// Berechtigung einer Apple-Komponente – auch am rohen TCC-Client (Bundle-ID oder Pfad) erkannt, falls sich
    /// der Client nicht auflösen ließ.
    public static func contains(_ grant: PermissionGrant) -> Bool {
        contains(grant.client) || AppleIdentifier.matches(grant.clientID) || isApplePath(grant.clientID)
    }

    /// Autostart-Eintrag von Apple.
    ///
    /// launchd-Einträge (mit Plist) bestimmen Label und Eigentümer selbst – `AssociatedBundleIdentifiers =
    /// com.apple.Safari` löst zum echten Safari auf, ein Programm in `~/…/Foo.app` kann jede Bundle-ID tragen. Sie gelten
    /// daher als Apple, wenn das Label `com.apple.` ist oder der Eigentümer Apple-Herkunft hat (Bundle-ID allein genügt
    /// nicht) – und in beiden Fällen nur, solange das nicht nachweislich Tarnung ist (`isDisguisedAsApple(_:)`).
    /// Andere Einträge (Login-Items, BTM) erkennt weiter Label oder Eigentümer.
    public static func contains(_ item: AutostartItem) -> Bool {
        guard item.plistPath != nil else {
            return AppleIdentifier.matches(item.label) || item.owner.map(contains) == true
        }
        return claimsApple(item) && !isDisguisedAsApple(item)
    }

    /// Der Eintrag gibt sich als Apple-Komponente aus (`com.apple.`-Label oder Eigentümer mit Apple-Herkunft), ohne dass
    /// das stimmt: die Adware-Tarnung (siehe `isDisguisedAsApple(_:)`). Nur für launchd-Einträge (mit Plist), die
    /// Label und Eigentümer selbst bestimmen; andere Einträge sind nie getarnt.
    static func isDisguised(_ item: AutostartItem) -> Bool {
        item.plistPath != nil && claimsApple(item) && isDisguisedAsApple(item)
    }

    /// Label `com.apple.` oder Eigentümer mit Apple-Herkunft (Bundle-ID allein genügt nicht): die bloße Behauptung
    /// eines launchd-Eintrags, ohne Prüfung auf Tarnung.
    private static func claimsApple(_ item: AutostartItem) -> Bool {
        let hasAppleOwner = item.owner.map { hasAppleOrigin(signing: $0.signing, path: $0.path) } == true
        return AppleIdentifier.matches(item.label) || hasAppleOwner
    }

    /// Echte Apple-Herkunft des ausgeführten Codes: `hasAppleOrigin` des Programms, außer es ist ein Interpreter mit
    /// Argumenten (`launchesInterpreter`) – dann führt ein Apple-Programm fremden Code aus. Label und Plist-Ort zählen
    /// hier nicht – beides kann jeder Benutzerprozess frei wählen.
    public static func hasAppleProgram(_ item: AutostartItem) -> Bool {
        !item.launchesInterpreter && hasAppleOrigin(signing: item.programSigning, path: item.program)
    }

    /// Behauptete Apple-Herkunft ohne Beleg – die klassische Adware-Tarnung (etwa
    /// `~/Library/LaunchAgents/com.apple.update.agent.plist` mit einem unsignierten Programm unter `~/Library/.x/`):
    /// Die Plist liegt außerhalb der Apple-Pfade, und der Code ist nachweislich nicht von Apple – ein Interpreter mit
    /// Argumenten oder ein geprüftes, nicht von Apple signiertes Programm. Ohne Signaturergebnis (`nil`, `.unknown`)
    /// gilt die Behauptung weiter: Ein Nachweis fehlt, und echte Apple-Einträge dürfen nicht veränderbar werden.
    ///
    /// `LaunchdSource` scannt derzeit nur Verzeichnisse außerhalb der Apple-Pfade; die Plist-Prüfung schützt echte
    /// Apple-Plists, falls ein Scan sie einmal einschließt (Apple startet dort auch Shell-Skripte).
    private static func isDisguisedAsApple(_ item: AutostartItem) -> Bool {
        guard let plistPath = item.plistPath, !isApplePath(plistPath) else { return false }
        if item.launchesInterpreter { return true }
        guard let signing = item.programSigning, signing.kind != .unknown else { return false }
        return !signing.isAppleSigned
    }

    /// Kanonischer absoluter Pfad: vorhandene Pfade per `realpath` (Symlinks, `..`, doppelte `/` wie der Kernel),
    /// sonst lexikalisch normalisiert; `nil` für relative Pfade.
    static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Namenstrenner nach „Xcode“ bei mehreren installierten Versionen (`Xcode-beta`, `Xcode_16.4`, `Xcode 26`).
    /// Drittanbieter-Apps wie `Xcodes.app` oder `XcodeCleaner.app` fallen so nicht darunter.
    private static let xcodeVersionSeparators = ["xcode-", "xcode_", "xcode "]

    /// `/applications/xcode.app/…` oder eine Variante wie `/applications/xcode-beta.app/…` (`directory` in
    /// Kleinschreibung).
    private static func isInsideXcode(_ directory: String) -> Bool {
        guard directory.hasPrefix(applications) else { return false }
        let bundle = directory.dropFirst(applications.count).prefix { $0 != "/" }
        guard bundle.hasSuffix(".app") else { return false }
        return bundle == "xcode.app" || xcodeVersionSeparators.contains(where: bundle.hasPrefix)
    }
}
