import Foundation
import GrantryShared

/// Sucht Reste einer installierten App (Spec v3 §3, nur auf Abruf). Ergebnis: die App selbst, danach je Ort sichere vor
/// unsicheren Treffern; nur Pfade, die der `RemovalGuard` zulässt, mit ihrer Identität (`FileIdentity`) für die erneute
/// Prüfung vor dem Papierkorb. Größen erst nach der Prüfung, begrenzt parallel, mit Frist (das App-Bundle mit der
/// großzügigeren) und abbrechbar. Nicht lesbare Reste-Orte meldet das Ergebnis eigens.
public struct LeftoverScanner: Sendable {
    /// Höchstens so viele Größen werden gleichzeitig gemessen.
    public static let maximumConcurrentMeasurements = 3

    private let layout: LibraryLayout
    private let sizes: any FileSizeMeasuring
    private let appSizes: any FileSizeMeasuring
    private let removalGuard: RemovalGuard

    /// - Parameters:
    ///   - sizes: misst die Reste.
    ///   - appSizes: misst das App-Bundle (großzügigere Frist).
    public init(
        layout: LibraryLayout = .standard,
        sizes: any FileSizeMeasuring = FileSizeCalculator(timeout: FileSizeCalculator.leftoverTimeout),
        appSizes: any FileSizeMeasuring = FileSizeCalculator(timeout: FileSizeCalculator.appTimeout)
    ) {
        self.layout = layout
        self.sizes = sizes
        self.appSizes = appSizes
        removalGuard = RemovalGuard(layout: layout)
    }

    /// Läuft nie auf dem Main Actor (Dateisystem, Größen). Nach einem Abbruch bleiben ungemessene Größen `.unknown`.
    @concurrent
    public func scan(for app: InstalledApp, installedApps: [InstalledApp]) async -> LeftoverScanResult {
        let verification = AppleAppVerification(catalog: SystemAppCatalog(layout: layout))
        let matcher = LeftoverMatcher(app: app, installedApps: installedApps, verification: verification)
        var unreadable: [String] = []
        var found: [LeftoverCandidate] = []
        for location in layout.leftoverLocations {
            guard let names = Self.entries(in: location.directory) else {
                unreadable.append(location.directory)
                continue
            }
            found += names.compactMap { name in
                matcher.match(name: name, in: location).map {
                    LeftoverCandidate(path: location.directory + "/" + name, kind: location.kind, confidence: $0.confidence,
                                      note: $0.note)
                }
            }
            .sorted(by: LeftoverCandidate.displayOrder)
        }
        let appleOwnerID = verification.appleOwnerID(of: app)
        let checked = ([LeftoverCandidate(path: app.path, kind: .appBundle, confidence: .safe)] + found).compactMap { candidate in
            guard case .allowed(let identity) = removalGuard.inspect(candidate.path, appleOwnerID: appleOwnerID) else {
                return nil as LeftoverCandidate?
            }
            return LeftoverCandidate(path: candidate.path, kind: candidate.kind, confidence: candidate.confidence,
                                     note: candidate.note, identity: identity)
        }
        let measured = await Self.measured(checked) { $0.kind == .appBundle ? appSizes : sizes }
        return LeftoverScanResult(candidates: measured, unreadableLocations: unreadable)
    }

    /// Nicht versteckte Einträge von `directory`; keine, wenn der Ordner fehlt oder selbst ein Symlink ist (nie folgen);
    /// `nil`, wenn er sich nicht lesen lässt (fehlende Rechte).
    static func entries(in directory: String) -> [String]? {
        guard FileType.isPlainDirectory(atPath: directory) else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return names.filter { !RawPath.isHidden($0) }
    }

    /// Ergebnis einer Messung in der Task-Gruppe (Struct statt Tupel mit Enum).
    private struct MeasuredSize: Sendable {
        let index: Int
        let size: FileSize
    }

    /// Größen mit höchstens `maximumConcurrentMeasurements` gleichzeitigen Messungen; nach einem Abbruch startet keine
    /// weitere. `sizer` wählt das Messwerkzeug je Kandidat.
    static func measured(
        _ candidates: [LeftoverCandidate], sizer: (LeftoverCandidate) -> any FileSizeMeasuring
    ) async -> [LeftoverCandidate] {
        var results = candidates
        await withTaskGroup(of: MeasuredSize.self) { group in
            var next = 0
            func startNext() {
                guard next < candidates.count else { return }
                let index = next, path = candidates[index].path
                let sizer = sizer(candidates[index])
                next += 1
                _ = group.addTaskUnlessCancelled {
                    MeasuredSize(index: index, size: Task.isCancelled ? .unknown : await sizer.measure(path))
                }
            }
            for _ in 0..<Self.maximumConcurrentMeasurements { startNext() }
            for await measurement in group {
                results[measurement.index].size = measurement.size
                startNext()
            }
        }
        return results
    }
}

/// Entscheidet je Eintrag, ob und wie sicher er zu einer App gehört.
struct LeftoverMatcher {
    struct Match: Equatable {
        let confidence: LeftoverConfidence
        let note: String?

        static let safe = Match(confidence: .safe, note: nil)

        static func uncertain(_ note: String?) -> Match { Match(confidence: .uncertain, note: note) }
    }

    /// Namenstreffer brauchen mindestens so viele Zeichen.
    static let minimumNameLength = 4
    /// Allgemeine Namen (und Sammel-Hersteller), die nichts über eine einzelne App sagen; klein.
    static let genericNames: Set<String> = [
        "app", "apps", "application", "applications", "data", "google", "microsoft", "adobe", "apple", "mozilla", "electron",
        "helper", "helpers", "updater", "update", "updates", "support", "cache", "caches", "logs", "temp", "default",
        "shared", "common", "plugin", "plugins", "settings", "config", "configuration", "preferences", "crashpad",
        "crashes", "sentry", "squirrel", "shipit", "sparkle", "framework", "frameworks", "resources", "library", "user",
        "users", "local", "service", "services", "agent", "daemon", "launcher", "installer", "setup", "uninstaller",
        "utility", "utilities", "tools", "java", "python", "node", "chromium", "browser", "media", "files", "documents",
        "downloads", "desktop", "backup", "backups", "sync", "cloud", "storage", "database", "runtime", "extensions",
        "profiles", "sessions", "state", "assets", "models", "network", "system", "native", "webkit", "widget", "widgets",
    ]
    /// Ordner, die macOS selbst in `Application Support`, `Caches` und `Logs` anlegt; klein. Ergänzt um die Namen der
    /// System-Apps (`SystemAppCatalog`).
    static let appleFolderNames: Set<String> = [
        "addressbook", "callhistorydb", "callhistorytransactions", "knowledge", "fileprovider", "clouddocs",
        "crashreporter", "diagnosticreports", "dock", "icloud", "mobilesync", "safari", "syncservices", "animoji",
        "accounts", "cloudkit", "coresimulator", "developer", "metadata", "quicklook", "spotlight", "siri", "facetime",
        "icdd", "ubiquity", "app store", "appstore", "applemediaservices", "bluetooth", "calendars", "contacts", "findmy",
        "homekit", "mail", "maps", "messages", "music", "notes", "photos", "podcasts", "reminders", "stocks", "voicememos",
        "weather", "books", "news", "shortcuts", "freeform", "passwords", "journal", "games", "preview", "textedit",
        "xcode", "itunes", "garageband", "imovie", "keynote", "pages", "numbers", "familycircle", "translation",
        "coreparsec", "sharedfilelist", "keychains", "recents", "screen sharing",
    ]

    private let layout: LibraryLayout
    private let hasDeveloperID: Bool
    private let appID: String?
    private let names: Set<String>
    private let isAppleApp: Bool
    private let isVerifiedAppleApp: Bool
    private let teamID: String?
    private let ownership: BundleIDOwnership
    /// Hinweis bei weiteren installierten Apps mit derselben Bundle-ID; Treffer per Bundle-ID sind dann unsicher.
    private let duplicateNote: String?
    private let vendorNote: String?
    /// Warum Team-Gruppen-Container unsicher sind; `nil` = sicher.
    private let teamContainerNote: String?

    init(app: InstalledApp, installedApps: [InstalledApp], verification: AppleAppVerification) {
        layout = verification.catalog.layout
        hasDeveloperID = app.signing.kind == .developerID
        let others = installedApps.filter { $0.id != app.id }
        let appID = app.bundleID?.lowercased()
        self.appID = appID
        isAppleApp = AppleComponent.contains(app.identity)
        isVerifiedAppleApp = verification.appleOwnerID(of: app) != nil
        teamID = app.signing.teamID
        ownership = BundleIDOwnership(others + [app], verification: verification)
        let duplicates = others.filter { appID != nil && $0.bundleID?.lowercased() == appID }.map(\.name)
        duplicateNote = OwnershipNote.mayBelong(to: duplicates)
        let teamMates = others.filter { $0.signing.teamID != nil && $0.signing.teamID == app.signing.teamID }.map(\.name)
        let vendor = app.bundleID.flatMap(VendorToken.of)
        let vendorMates = others.filter { vendor != nil && $0.bundleID.flatMap(VendorToken.of) == vendor }.map(\.name)
        vendorNote = OwnershipNote.mayBelong(to: vendorMates + teamMates)
        teamContainerNote = if !teamMates.isEmpty {
            "Team-ID auch bei: \(Set(teamMates).sorted().joined(separator: ", "))"
        } else if !vendorMates.isEmpty {
            OwnershipNote.mayBelong(to: vendorMates)
        } else if !others.allSatisfy(Self.hasKnownTeam) {
            "Team-ID nicht bei allen Apps prüfbar"
        } else {
            nil
        }
        let excluded = Self.appleFolderNames.union(verification.catalog.names.map(Self.normalized))
        names = Set(([app.name] + (vendor.map { [$0] } ?? [])).map(Self.normalized).filter { name in
            name.count >= Self.minimumNameLength && !Self.genericNames.contains(name) && !excluded.contains(name)
        })
    }

    func match(name: String, in location: LeftoverLocation) -> Match? {
        if location.naming == .groupContainer { return groupContainerMatch(name, in: location) }
        if let appID, let identifier = location.naming.identifier(in: name), ownership.owner(of: identifier) == appID {
            return ownedMatch(in: location)
        }
        guard location.allowsNameMatches, !isAppleApp, AppleEntryName.identifier(in: name) == nil,
              ownership.owner(of: name) == nil, names.contains(Self.normalized(name))
        else { return nil }
        return .uncertain(vendorNote)
    }

    /// Für Namensvergleiche: ohne Groß-/Kleinschreibung und diakritische Zeichen.
    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Team-ID bekannt oder nachweislich keine: Apple-signiert (Apple-Apps tragen keine Team-ID), ad hoc, unsigniert.
    static func hasKnownTeam(_ app: InstalledApp) -> Bool {
        app.signing.teamID != nil || [.apple, .adHoc, .unsigned].contains(app.signing.kind)
    }

    /// Treffer per Bundle-ID: bei Duplikaten oder systemweiten Orten ohne Developer-ID-Signatur unsicher.
    private func ownedMatch(in location: LeftoverLocation) -> Match {
        if let duplicateNote { return .uncertain(duplicateNote) }
        if layout.isSystemWide(location) && !hasDeveloperID { return .uncertain(OrphanScanner.systemWideNote) }
        return .safe
    }

    /// `group.<id>` wie die Bundle-ID; `<TEAM>.…` sicher nur, wenn keine andere installierte App dieses Team oder diesen
    /// Hersteller hat und alle anderen eine bekannte Team-ID haben; Apple-Kennungen nur für nachweisliche Apple-Apps.
    private func groupContainerMatch(_ name: String, in location: LeftoverLocation) -> Match? {
        switch GroupContainerName(name) {
        case .group(let rest)?:
            guard let appID, ownership.owner(of: rest) == appID else { return nil }
            return ownedMatch(in: location)
        case .team(let team, let rest)?:
            guard let teamID, team == teamID, isVerifiedAppleApp || !AppleEntryName.isApple(rest) else { return nil }
            return teamContainerNote.map(Match.uncertain) ?? .safe
        case nil:
            return nil
        }
    }
}
