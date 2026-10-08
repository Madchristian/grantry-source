import Foundation

/// Ordnet die neuen Einträge einer Beobachtung dem beobachteten Tool zu (#127): „wahrscheinlich zugehörig“ oder
/// „Zuordnung unsicher“, jeweils mit Begründung. Nur zugehörige Einträge sind beim Aufräumen vorausgewählt.
///
/// **Apps des Tools:** neue Apps, deren Name oder Bundle-ID zum Beobachtungsnamen passt; passt keine, gilt die einzige
/// neue App als die des Tools. Weitere neue Apps gehören dazu, wenn Team-ID oder Bundle-ID-Präfix mit einer davon
/// übereinstimmen.
///
/// **Berechtigungen und Autostart-Einträge** gehören dazu, wenn gegenüber einer App des Tools eins zutrifft: gleiche
/// Bundle-ID oder Pfad des Eigentümers, Bundle-ID bzw. Label beginnt mit deren Bundle-ID, gleicher Hersteller-Präfix
/// (nicht Apple, keine eingebettete Bibliothek), Programm liegt in der App oder in einem Support-Ordner der App, gleiche
/// Team-ID. Ohne App des Tools (etwa bei Kommandozeilenwerkzeugen) zählt, ob ein ganzes Wort des Eintrags (Label,
/// Pfadbestandteil, Name) zum Beobachtungsnamen passt. Die einzige neue App zählt nur dann ohne Namensbezug, wenn sie
/// nicht von Apple signiert ist – ein nebenbei installiertes Apple-Programm soll nie vorausgewählt sein.
/// Alles andere – auch Gegenstände, die die Regeln nicht kennen – ist „Zuordnung unsicher“.
public struct ObservationAttribution: Sendable {
    public enum Verdict: Hashable, Sendable {
        case likely(String)
        case uncertain(String)

        public var isLikely: Bool {
            if case .likely = self { true } else { false }
        }

        /// Begründung im Klartext.
        public var reason: String {
            switch self {
            case .likely(let reason), .uncertain(let reason): reason
            }
        }
    }

    static let noRelation = "Kein Bezug zu einer neu installierten App oder zum Namen der Beobachtung erkennbar."
    static let unknownSubject = "Für diese Art von Eintrag lässt sich die Zuordnung nicht prüfen."

    /// Neue Apps, die zum Tool gehören.
    public let toolApps: [InstalledApp]
    private let appVerdicts: [String: Verdict]
    private let name: ObservationName

    public init(observationName: String, newApps: [InstalledApp]) {
        let name = ObservationName(observationName)
        let primary = Self.primaryApps(of: newApps, name: name)
        var verdicts: [String: Verdict] = [:]
        for app in newApps {
            verdicts[app.id] = Self.verdict(for: app, primary: primary, name: name, isOnlyNewApp: newApps.count == 1)
        }
        self.name = name
        appVerdicts = verdicts
        toolApps = newApps.filter { verdicts[$0.id]?.isLikely == true }
    }

    /// Zuordnung des neuen Gegenstands `subject`.
    public func verdict(for subject: ChangeSubject) -> Verdict {
        if case .installedApp(let app) = subject { return appVerdicts[app.id] ?? .uncertain(Self.noRelation) }
        if case .grant(let grant) = subject { return verdict(for: Evidence(grant)) }
        if case .autostartItem(let item) = subject { return verdict(for: Evidence(item)) }
        return .uncertain(Self.unknownSubject)
    }

    private func verdict(for evidence: Evidence) -> Verdict {
        for app in toolApps {
            if let reason = evidence.relation(to: app) { return .likely(reason) }
        }
        if toolApps.isEmpty, name.matches(any: evidence.names) { return .likely(name.matchReason) }
        return .uncertain(Self.noRelation)
    }

    // MARK: Apps

    /// Neue Apps, deren Name oder Bundle-ID zum Beobachtungsnamen passt; sonst die einzige neue App.
    private static func primaryApps(of apps: [InstalledApp], name: ObservationName) -> [InstalledApp] {
        let matching = apps.filter { name.matches(any: [$0.name, $0.bundleID].compactMap(\.self)) }
        if !matching.isEmpty { return matching }
        return apps.count == 1 && !isApple(apps[0]) ? apps : []
    }

    private static func isApple(_ app: InstalledApp) -> Bool {
        app.signing.isAppleSigned || app.origin == .apple
    }

    private static func verdict(
        for app: InstalledApp, primary: [InstalledApp], name: ObservationName, isOnlyNewApp: Bool
    ) -> Verdict {
        if name.matches(any: [app.name, app.bundleID].compactMap(\.self)) { return .likely(name.matchReason) }
        if isOnlyNewApp, !isApple(app) { return .likely("Einzige neue App während der Beobachtung.") }
        for other in primary where other.id != app.id {
            if let team = app.signing.teamID, team == other.signing.teamID {
                return .likely("Gleiches Team wie „\(other.name)“ (\(team)).")
            }
            if let reason = BundleIDRelation.reason(app.bundleID, comparedTo: other) { return .likely(reason) }
        }
        return .uncertain(noRelation)
    }
}

/// Belege eines Eintrags, die ihn mit einer App verbinden können.
private struct Evidence {
    var bundleIDs: [String] = []
    var paths: [String] = []
    var teamIDs: [String] = []
    /// Texte für den Abgleich mit dem Beobachtungsnamen.
    var names: [String] = []

    init(_ grant: PermissionGrant) {
        bundleIDs = [grant.client.bundleID].compactMap(\.self)
        paths = [grant.client.path, grant.clientID.hasPrefix("/") ? grant.clientID : nil].compactMap(\.self)
        teamIDs = [grant.client.signing.teamID].compactMap(\.self)
        names = [grant.client.displayName, grant.clientID]
    }

    init(_ item: AutostartItem) {
        bundleIDs = [item.owner?.bundleID, item.label].compactMap(\.self)
        paths = [item.owner?.path, item.program].compactMap(\.self)
        teamIDs = [item.owner?.signing.teamID, item.programSigning?.teamID].compactMap(\.self)
        names = [item.label, item.program, item.owner?.displayName].compactMap(\.self)
    }

    /// Begründung, warum der Eintrag zu `app` gehört; `nil`, wenn nichts verbindet.
    func relation(to app: InstalledApp) -> String? {
        let appPath = InstallationIndex.canonical(app.path)
        for path in paths {
            let canonical = InstallationIndex.canonical(path)
            if canonical == appPath || canonical.hasPrefix(appPath + "/") { return "Liegt in „\(app.name)“." }
        }
        for bundleID in bundleIDs {
            if let reason = BundleIDRelation.reason(bundleID, comparedTo: app) { return reason }
        }
        if paths.contains(where: { SupportFolder.belongs($0, to: app) }) {
            return "Programm liegt im Support-Ordner von „\(app.name)“."
        }
        if let team = app.signing.teamID, teamIDs.contains(team) {
            return "Gleiches Team wie „\(app.name)“ (\(team))."
        }
        return nil
    }
}

/// Beziehung zweier Bundle-IDs (bzw. eines bundle-ID-artigen Labels) ohne Groß-/Kleinschreibung.
enum BundleIDRelation {
    /// Hersteller-Präfixe, die viele fremde Apps teilen – kein Beleg für Zugehörigkeit.
    /// `com.todesktop` ist eine Plattform, unter der viele fremde Apps erscheinen (Cursor u. a.).
    static let genericVendors: Set<String> = ["com.github", "io.github", "com.example", "org.example", "com.todesktop"]

    static func reason(_ identifier: String?, comparedTo app: InstalledApp) -> String? {
        guard let identifier = identifier?.lowercased(), let bundleID = app.bundleID?.lowercased() else { return nil }
        if identifier == bundleID { return "Gehört zu „\(app.name)“." }
        if identifier.hasPrefix(bundleID + ".") { return "Bundle-ID beginnt wie die von „\(app.name)“." }
        guard let vendor = vendor(of: bundleID), vendor == Self.vendor(of: identifier) else { return nil }
        return "Gleicher Hersteller wie „\(app.name)“ (\(vendor))."
    }

    /// Die ersten zwei Bestandteile einer plausiblen, nicht generischen Bundle-ID (`com.anthropic`); `nil` für Apple,
    /// eingebettete Bibliotheken und generische Präfixe.
    static func vendor(of identifier: String) -> String? {
        guard BundleIDShape.isPlausible(identifier), !BundleIDShape.isApple(identifier),
              !BundleIDShape.isSharedLibrary(identifier) else { return nil }
        let vendor = identifier.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
        return genericVendors.contains(vendor) ? nil : vendor
    }
}

/// Support-Ordner einer App: `…/Library/Application Support/<Ordner>/…`, wobei der Ordner wie App-Name oder Bundle-ID
/// heißt bzw. mit der Bundle-ID beginnt.
enum SupportFolder {
    private static let marker = "/Library/Application Support/"

    static func belongs(_ path: String, to app: InstalledApp) -> Bool {
        guard let range = path.range(of: marker) else { return false }
        guard let folder = path[range.upperBound...].split(separator: "/").first.map(String.init)?.lowercased() else {
            return false
        }
        if folder == app.name.lowercased() { return true }
        guard let bundleID = app.bundleID?.lowercased() else { return false }
        return folder == bundleID || folder.hasPrefix(bundleID + ".")
    }
}

/// Beobachtungsname als Suchbegriffe: Wörter ab drei Zeichen ohne allgemeine Begriffe („Desktop“, „App“ …).
struct ObservationName: Sendable {
    static let genericWords: Set<String> = [
        "app", "apps", "desktop", "mac", "macos", "for", "the", "and", "und", "cli", "code", "helper", "agent", "beta",
        "pro", "tool", "tools", "installation", "install", "update", "neu", "new",
    ]

    let text: String
    let tokens: [String]

    init(_ text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens = Self.words(in: self.text)
            .filter { $0.count >= 3 && !Self.genericWords.contains($0) }
    }

    /// Ganze Wörter, keine Teilzeichenketten – „Ice“ soll nicht „service“ treffen, „Ray“ nicht „Library“.
    func matches(any candidates: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        return candidates.contains { candidate in
            let words = Set(Self.words(in: candidate))
            return tokens.contains(where: words.contains)
        }
    }

    static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    var matchReason: String { "Name passt zu „\(text)“." }
}
