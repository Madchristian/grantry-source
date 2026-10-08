import Foundation

/// Update-Feed von Grantry (Spec Update-Hinweis §2). Die URL ist einkompiliert und ändert sich nie.
public enum UpdateFeed {
    /// Einziger Host, dem Download- und Release-Notes-Links aus dem Feed angehören dürfen.
    public static let host = "grantry.cstrube.de"
    public static let url = URL(string: "https://grantry.cstrube.de/appcast.xml")!

    /// Was bei der Prüfung übertragen wird; gleichlautend im Onboarding und in den Einstellungen.
    public static let privacyNote =
        "Grantry fragt einmal täglich bei grantry.cstrube.de nach einer neuen Version. Dabei werden nur die Version von Grantry, die macOS-Version und die Mac-Architektur übertragen."

    // MARK: Grenzen gegen einen Feed, der Speicher und Parserzeit flutet (#103)
    //
    // Ein echter Feed bleibt weit darunter (wenige KB, wenige Einträge, kurze Felder). Wird eine Grenze überschritten,
    // gilt der Feed als ungültig (`FeedFetchError.tooLarge`, `AppcastError.tooLarge`; `UpdateChecker` meldet beides als
    // `.invalidFeed`) – bis auf die Eintragszahl, siehe `maximumItems`.

    /// Größte Antwort in Byte (nach dem Entpacken), die der Abruf annimmt: 1 MiB. `URLSessionFeedFetcher` zählt sie
    /// beim Empfangen mit, `AppcastParser` prüft sie noch einmal.
    public static let maximumFeedBytes = 1_048_576

    /// Höchstzahl der `<item>`-Einträge, die der Parser liest. Anders als die übrigen Grenzen ist das **kein Fehler**:
    /// Der Feed wächst mit jedem Release, und ein Fehler beim n-ten Eintrag ließe jeden installierten Client dauerhaft
    /// keine Updates mehr sehen, ohne dass ein Update das beheben könnte. Darüber liest der Parser nur die ersten
    /// `maximumItems` Einträge (die neuesten stehen oben) und ignoriert den Rest. Dass der Feed gar nicht erst so lang
    /// wird, sorgt `scripts/appcast.swift` (behält nur die neuesten Einträge, deutlich weniger als hier).
    public static let maximumItems = 200

    /// Längster Text eines ausgewerteten Feldes (Kind-Element von `<item>` oder Attribut von `<enclosure>`) in Byte
    /// (UTF-8). Das Längste darin ist eine URL, und die ist deutlich kürzer. Text anderer Elemente (etwa eine lange
    /// `<description>`) wird gar nicht erst gesammelt und zählt nicht.
    public static let maximumFieldLength = 4_096

    /// Tiefste Verschachtelung geöffneter Elemente im ganzen Dokument. Der echte Feed kommt auf 5
    /// (`rss`, `channel`, `item`, `sparkle:deltas`, `enclosure`).
    public static let maximumNestingDepth = 32

    /// `true` für `https`-Links auf genau `host`, ohne eigenen Port und ohne Zugangsdaten in der URL.
    static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == host && url.port == nil && url.user == nil && url.password == nil
    }
}
