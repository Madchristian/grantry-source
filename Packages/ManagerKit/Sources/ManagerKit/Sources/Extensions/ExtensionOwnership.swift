import Foundation

/// Zu welcher App eine Erweiterung gehört.
public enum ExtensionOwnership: Hashable, Sendable, Codable {
    /// Genau eine App im Inventar; `evidence` sagt, woran sie erkannt wurde.
    case app(path: String, evidence: OwnershipEvidence)
    /// Keine App bringt die Erweiterung mit und keine hat ihr Team: verwaist.
    case missing
    /// Mehrere Apps kommen in Frage (`candidates`, sortiert), oder das Fehlen ist nicht belegt (`candidates` leer: keine
    /// Team-ID oder nicht alle Apps lesbar).
    case unclear(candidates: [String])
}

/// Woran die zugehörige App erkannt wurde.
public enum OwnershipEvidence: String, Hashable, Sendable, Codable {
    /// Die App bringt die Erweiterung in `Contents/Library/SystemExtensions` mit.
    case bundleID
    /// Die App ist die einzige des Teams im Inventar.
    case teamID
}

/// Ordnet Erweiterungen den Apps im Inventar zu: zuerst über die Bundle-IDs, die eine App in
/// `Contents/Library/SystemExtensions` mitbringt, sonst über die Team-ID.
///
/// Eine einbettende App zählt nur, wenn ihre Team-ID der Erweiterung nicht widerspricht – eine fremde App mit gleicher
/// Bundle-ID macht eine Erweiterung nicht zur „zugehörigen“. Ergebnis „App fehlt“ nur mit Team-ID und vollständig
/// gelesenem Inventar; sonst „unklar“ (konservativ, die Bewertung meldet daraus keinen Rest).
public struct AppExtensionIndex: Hashable, Sendable {
    /// Apps mit Team-ID (Pfad → Team-ID).
    private let teams: [String: String]
    /// Eingebettete Bundle-ID → Pfade der Apps, die sie mitbringen.
    private let embeddingApps: [String: Set<String>]
    /// Apps oder Bundles, deren Erweiterungen nicht gelesen wurden.
    public let unreadable: [UnreadableExtension]

    init(apps: [InstalledApp], embedded: [String: [String]], unreadable: [UnreadableExtension]) {
        teams = Dictionary(apps.compactMap { app in app.signing.teamID.map { (app.path, $0) } }, uniquingKeysWith: { first, _ in first })
        embeddingApps = embedded.reduce(into: [:]) { index, entry in
            for bundleID in entry.value { index[bundleID, default: []].insert(entry.key) }
        }
        self.unreadable = unreadable
    }

    /// `true`, wenn alle Apps gelesen wurden; nur dann ist „App fehlt“ belegt.
    public var isComplete: Bool { unreadable.isEmpty }

    public func owner(of systemExtension: SystemExtension) -> ExtensionOwnership {
        owner(bundleID: systemExtension.bundleID, teamID: systemExtension.teamID)
    }

    /// Plug-ins bettet keine App ein; es zählt die Team-ID ihrer Signatur.
    public func owner(of plugin: ServicePlugin) -> ExtensionOwnership {
        owner(bundleID: plugin.bundleID, teamID: plugin.signing.teamID)
    }

    public func owner(bundleID: String, teamID: String?) -> ExtensionOwnership {
        let embedding = (embeddingApps[bundleID] ?? []).filter { path in
            guard let teamID, let appTeam = teams[path] else { return true }
            return appTeam == teamID
        }
        if let decided = Self.decision(embedding, evidence: .bundleID) { return decided }
        guard let teamID else { return .unclear(candidates: []) }
        if let decided = Self.decision(teams.filter { $0.value == teamID }.keys, evidence: .teamID) { return decided }
        return isComplete ? .missing : .unclear(candidates: [])
    }

    /// Eine App → zugeordnet, mehrere → unklar, keine → `nil` (nächster Hinweis).
    private static func decision(_ candidates: some Collection<String>, evidence: OwnershipEvidence) -> ExtensionOwnership? {
        guard candidates.count > 1 else { return candidates.first.map { .app(path: $0, evidence: evidence) } }
        return .unclear(candidates: candidates.sorted())
    }
}

extension AppExtensionIndex {
    /// Liest die eingebetteten Systemerweiterungen der Apps auf `ExtensionWork.queue` mit Frist.
    public static func load(apps: [InstalledApp]) async throws -> AppExtensionIndex {
        let builder = AppExtensionIndexBuilder()
        let index = await ExtensionWork.queue.run {
            ExtensionWork.fileSystemGuard.run(timeout: ExtensionWork.timeout) { builder.build(apps: apps) }
        }
        guard let index else { throw ExtensionReadError.unavailable("Erweiterungen der Apps nicht rechtzeitig gelesen") }
        return index
    }
}

/// Liest `Contents/Library/SystemExtensions` der Apps (`*.systemextension`, DriverKit `*.dext`;
/// `ExtensionBundleScanner`) – auch die der Hilfs-Apps eine Ebene tiefer in `Contents/Applications` (iCUE bettet seinen
/// Treiber so ein); sie zählen für die App im Inventar. Synchron und blockierend.
///
/// Apps, die selbst ein Symlink sind (`InstalledApp.symlinkTarget`), bleiben unberührt – Grantry folgt ihnen für keine
/// Prüfung, ihre Team-ID ist ohnehin unbekannt. Apps auf Netzlaufwerken werden nicht gelesen und machen den Index
/// unvollständig.
struct AppExtensionIndexBuilder: Sendable {
    static let systemExtensionsFolder = "Contents/Library/SystemExtensions"
    static let helperAppsFolder = "Contents/Applications"
    static let systemExtensionSuffixes = [".systemextension", ".dext"]
    static let maximumEntriesPerApp = 50

    let volumeCheck: ExtensionVolumeCheck

    init(volumes: @escaping @Sendable () -> [MountedVolume] = MountedVolume.current) {
        volumeCheck = ExtensionVolumeCheck(volumes: volumes)
    }

    func build(apps: [InstalledApp]) -> AppExtensionIndex {
        let volumes = volumeCheck.snapshot()
        var embedded: [String: [String]] = [:]
        var unreadable: [UnreadableExtension] = []
        for app in apps where app.symlinkTarget == nil {
            if let reason = volumes.refusal(forPath: app.path) {
                unreadable.append(UnreadableExtension(path: app.path, reason: reason))
                continue
            }
            let helpers = Self.scanner(app.path, Self.helperAppsFolder, suffixes: [".app"]).scan()
            unreadable += helpers.unreadable
            for bundlePath in [app.path] + helpers.bundles.map(\.path) {
                let scan = Self.scanner(bundlePath, Self.systemExtensionsFolder, suffixes: Self.systemExtensionSuffixes).scan()
                embedded[app.path, default: []] += scan.bundles.map(\.bundleID)
                unreadable += scan.unreadable
            }
        }
        return AppExtensionIndex(apps: apps, embedded: embedded, unreadable: unreadable)
    }

    private static func scanner(_ bundlePath: String, _ folder: String, suffixes: [String]) -> ExtensionBundleScanner {
        ExtensionBundleScanner(
            directory: (bundlePath as NSString).appendingPathComponent(folder), suffixes: suffixes,
            maximumEntries: maximumEntriesPerApp
        )
    }
}
