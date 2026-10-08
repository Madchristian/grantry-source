import Foundation
import os
import Synchronization

/// Quelle des App-Inventars (Spec v3 §2): App-Bundles unter `/Applications` und `~/Applications`.
///
/// - Abstieg höchstens `maximumFolderDepth` Ordner unter die Wurzel, nie in Bundles, versteckte Ordner oder Symlinks.
///   Versteckte Bundles (`.Name.app`) werden erfasst (Review M3).
/// - Symlink-Bundles: Zeigt der Link ins versiegelte System (`/Applications/Safari.app` → Cryptex), entfällt er; sonst
///   erscheint er als Eintrag mit `symlinkTarget`, nur aus den Angaben des Links – dem Ziel folgt keine Prüfung.
/// - Je Bundle: Metadaten und Name (`AppBundleReader`, `AppNameReading`, ohne Blockieren und ohne Launch Services),
///   Signatur (`SigningInspecting`, mit Fingerabdruck-Cache und Zeitgrenze), Herkunft (`AppOriginDetector`,
///   Homebrew-Index je Lauf neu gelesen), Architektur (`MachOHeader`).
/// - Metadaten und Architektur werden je Pfad und `FileFingerprint` gemerkt (Review M5) – ein Scan ohne Änderungen liest
///   nur Attribute. Eine geänderte Sprache wirkt erst nach einer Änderung des Bundles.
/// - Gesammelt wird auf einer eigenen seriellen Queue, nie im kooperativen Pool (Review M5): Signaturprüfungen warten
///   bis zu ihrer Frist.
/// - Ein vorhandener, aber nicht lesbarer Ordner (auch eine Wurzel) landet in `incompleteFolders`: Der Scan schreibt
///   seine Apps fort, statt sie als entfernt zu melden (Review M3); eine fehlende Wurzel zählt als leer.
/// - Fällt die Signaturprüfung aus (Zeitüberschreitung, erschöpfter Guard), trägt die App `SigningLimitation.notChecked`
///   und den Fingerabdruck ihres Hauptprogramms; der Scan schreibt dann nur bei unverändertem Hauptprogramm die letzte
///   Signatur fort, als veraltet markiert. Ausfälle und ein erschöpfter Guard erscheinen als Einschränkung
///   (`InventoryContribution.limitations`, Review M2).
/// - Größe und „zuletzt benutzt“ liefert `AppDetailsLoader` getrennt – sie blockieren den Scan nie.
public struct AppInventorySource: InventorySource {
    public struct Root: Sendable, Equatable {
        public let path: String
        public let location: AppLocation

        public init(path: String, location: AppLocation) {
            self.path = path
            self.location = location
        }
    }

    public let id = SourceID.apps
    /// Ein Bundle liegt höchstens so viele Ordner unter seiner Wurzel
    /// (`/Applications/Canon Utilities/EOS Utility/EU3/EOS Utility 3.app`); gilt auch für den `RemovalGuard`.
    public static let maximumFolderDepth = 3

    public static var standardRoots: [Root] {
        [
            Root(path: "/Applications", location: .applications),
            Root(path: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path,
                 location: .userApplications),
        ]
    }

    /// Flach zu beobachtende Ordner (`ScanTriggers.shallowPaths`).
    public static var watchedDirectories: [String] { standardRoots.map(\.path) }

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "apps")

    private let roots: [Root]
    private let inspector: any SigningInspecting
    private let caskrooms: [String]
    private let names: any AppNameReading
    private let queue = DispatchQueue(label: "de.cstrube.Grantry.app-inventory", qos: .utility)
    private let bundles = BundleCache()
    /// Guard der Signaturprüfung – ist er erschöpft, meldet der Scan das als Einschränkung.
    private let signingGuard: BlockingCallGuard
    /// Guard der Tiefenprüfung (`SecuritySignatureValidator`) – ebenso (Review N5).
    private let deepValidationGuard: BlockingCallGuard

    /// - Parameter names: Quelle der Anzeigenamen (Standard `BundleNameReader`, ohne Launch Services).
    public init(
        roots: [Root] = standardRoots,
        inspector: any SigningInspecting = CachingSigningInspector(),
        caskrooms: [String] = HomebrewCaskIndex.standardCaskrooms,
        names: any AppNameReading = BundleNameReader()
    ) {
        self.init(roots: roots, inspector: inspector, caskrooms: caskrooms, names: names, signingGuard: .signing)
    }

    init(
        roots: [Root], inspector: any SigningInspecting, caskrooms: [String], names: any AppNameReading,
        signingGuard: BlockingCallGuard, deepValidationGuard: BlockingCallGuard = .deepValidation
    ) {
        self.deepValidationGuard = deepValidationGuard
        self.roots = roots
        self.inspector = inspector
        self.caskrooms = caskrooms
        self.names = names
        self.signingGuard = signingGuard
    }

    public func collect() async throws -> InventoryContribution {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: collectNow()) }
        }
    }

    private func collectNow() -> InventoryContribution {
        let casks = HomebrewCaskIndex.load(caskrooms: caskrooms)
        var apps: [InstalledApp] = []
        var incomplete: [String] = []
        for root in roots {
            let scan = Self.scan(root: root.path)
            incomplete += scan.unreadableFolders
            apps += scan.entries.compactMap { entry in
                switch entry {
                case .bundle(let path): app(at: path, location: root.location, casks: casks)
                case .symlink(let path, let target): Self.symlinkedApp(at: path, target: target, location: root.location)
                }
            }
        }
        for folder in incomplete {
            Self.logger.error("App-Ordner nicht lesbar, Apps darin bleiben erhalten: \(PathDisplay.abbreviatingHome(folder), privacy: .public)")
        }
        let incompleteFolders = incomplete.sorted()
        return InventoryContribution(installedApps: apps.sorted { $0.path < $1.path }, incompleteFolders: incompleteFolders,
                                     limitations: Self.limitations(ofIncompleteFolders: incompleteFolders),
                                     retryableLimitations: limitations(of: apps))
    }

    /// Je nicht lesbarem Ordner eine Einschränkung (#142): Seine Apps zeigen den letzten bekannten Stand.
    private static func limitations(ofIncompleteFolders folders: [String]) -> [String] {
        folders.map { "Ordner \($0) nicht lesbar – Apps darin zeigen den letzten bekannten Stand" }
    }

    /// Einschränkungen des Scans im Klartext: Apps ohne Signaturprüfung und erschöpfte Guards (Signatur, Tiefenprüfung) –
    /// Zeitüberschreitungen, die ein späterer Scan beheben kann.
    private func limitations(of apps: [InstalledApp]) -> [String] {
        let unchecked = apps.count { $0.signingLimitation == .notChecked }
        var texts: [String] = []
        if signingGuard.isExhausted {
            texts.append("Signaturprüfung ausgesetzt, bis hängende Prüfungen enden")
        }
        if deepValidationGuard.isExhausted {
            texts.append("Tiefenprüfung der Signaturen ausgesetzt, bis hängende Prüfungen enden")
        }
        if unchecked > 0 {
            let apps = unchecked == 1 ? "1 App" : "\(unchecked) Apps"
            texts.append("Signatur von \(apps) nicht geprüft (Zeitüberschreitung), zuletzt bekannte Werte gelten weiter")
        }
        return texts.map { "Prüfung eingeschränkt: \($0)" }
    }

    // MARK: Ordner durchsuchen

    /// Fund beim Durchsuchen: ein Bundle-Verzeichnis oder ein Symlink-Bundle samt Ziel.
    enum Entry: Hashable {
        case bundle(String)
        case symlink(String, target: String)

        var path: String {
            switch self {
            case .bundle(let path), .symlink(let path, _): path
            }
        }
    }

    /// Ergebnis des Durchsuchens einer Wurzel (Struct statt Tupel, siehe Leitplanke 2).
    struct Scan: Equatable {
        var entries: [Entry] = []
        /// Vorhandene, aber nicht lesbare Ordner (kanonisch) – auch die Wurzel selbst.
        var unreadableFolders: [String] = []
    }

    /// Bundles unter `root`, nach Pfad sortiert (kanonische Ordner). Fehlt `root`: nichts.
    static func scan(root: String, maximumDepth: Int = maximumFolderDepth) -> Scan {
        guard FileType.exists(atPath: root), let canonical = AppleComponent.canonicalPath(root) else { return Scan() }
        var result = Scan()
        var pending = [PendingFolder(path: canonical, depth: 0)]
        while let folder = pending.popLast() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
                result.unreadableFolders.append(folder.path)
                continue
            }
            for name in names {
                let path = folder.path + "/" + name
                let isBundleName = RawPath.hasExtension(name, "app")
                guard let info = FileType.linkStatus(of: path) else { continue }
                if FileType.isSymbolicLink(info) {
                    if isBundleName, let target = symlinkTarget(of: path, in: folder.path) { result.entries.append(.symlink(path, target: target)) }
                } else if FileType.isDirectory(info) {
                    if isBundleName {
                        result.entries.append(.bundle(path))
                    } else if !RawPath.isHidden(name), folder.depth < maximumDepth {
                        pending.append(PendingFolder(path: path, depth: folder.depth + 1))
                    }
                }
            }
        }
        result.entries.sort { $0.path < $1.path }
        result.unreadableFolders.sort()
        return result
    }

    /// Ordner, der noch durchsucht wird (Struct statt Tupel, siehe Leitplanke 2).
    private struct PendingFolder {
        let path: String
        let depth: Int
    }

    /// Absolutes Ziel des Symlinks `path` (vorhanden: kanonisch, sonst lexikalisch); `nil`, wenn es im versiegelten
    /// System liegt (`AppleComponent.isSystemPath`) oder sich nicht lesen lässt. Nur `readlink`/`realpath`, nichts wird
    /// geöffnet.
    private static func symlinkTarget(of path: String, in folder: String) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        let absolute = destination.hasPrefix("/") ? destination : folder + "/" + destination
        let target = FileType.exists(atPath: absolute) && FileType.status(of: absolute) != nil
            ? AppleComponent.canonicalPath(path) ?? absolute
            : URL(fileURLWithPath: absolute).standardizedFileURL.path
        return AppleComponent.isSystemPath(target) ? nil : target
    }

    // MARK: Einträge

    private func app(at path: String, location: AppLocation, casks: HomebrewCaskIndex) -> InstalledApp? {
        guard let bundle = bundles.bundle(at: path, reading: { Self.readBundle(at: $0, names: names) }) else {
            Self.logger.notice("Kein lesbares App-Bundle: \(PathDisplay.abbreviatingHome(path), privacy: .public)")
            return nil
        }
        let info = bundle.info
        let inspection = inspector.inspection(ofPath: path)
        let signing = inspection.info
        return InstalledApp(
            path: path, bundleID: info.bundleID, name: info.name, shortVersion: info.shortVersion,
            buildVersion: info.buildVersion, location: location,
            origin: AppOriginDetector.origin(ofBundleAt: path, info: info, signing: signing, casks: casks),
            signing: signing, architecture: bundle.architecture,
            // Bei jedem Scan neu: Der Bundle-Cache bemerkt einen Austausch nur des Hauptprogramms nicht.
            executableFingerprint: info.executablePath.flatMap(FileFingerprint.init(of:)),
            signingLimitation: inspection.isConclusive ? nil : .notChecked
        )
    }

    private static func readBundle(at path: String, names: any AppNameReading) -> CachedBundle? {
        AppBundleReader.read(bundleAt: path, names: names).map { info in
            CachedBundle(info: info, architecture: info.executablePath.map(MachOHeader.architecture(ofExecutableAt:)) ?? .unknown)
        }
    }

    /// Eintrag eines Symlink-Bundles nur aus dem Link selbst: Name aus dem Dateinamen, sonst nichts bekannt.
    private static func symlinkedApp(at path: String, target: String, location: AppLocation) -> InstalledApp {
        InstalledApp(
            path: path, bundleID: nil, name: BundleNameReader.fallbackName(of: path), shortVersion: nil, buildVersion: nil,
            location: location, origin: .unverified, signing: .unknown, architecture: .unknown, symlinkTarget: target
        )
    }
}

/// Gemerkte Metadaten und Architektur eines Bundles.
private struct CachedBundle: Sendable {
    let info: AppBundleInfo
    let architecture: AppArchitecture
}

/// Metadaten je Pfad, gültig, solange der Fingerabdruck gleich bleibt – bei iOS-Apps im Wrapper der des inneren
/// Bundles (dort liegen Info.plist und Hauptprogramm). Nicht lesbare Bundles werden nicht gemerkt.
private final class BundleCache: Sendable {
    private let entries = Mutex(FingerprintCache<CachedBundle>())

    func bundle(at path: String, reading read: (String) -> CachedBundle?) -> CachedBundle? {
        let source = WrapperLayout(path: path)?.innerBundle ?? path
        guard let fingerprint = FileFingerprint(of: source) else { return read(path) }
        if let cached = entries.withLock({ $0.value(for: path, matching: fingerprint) }) { return cached }
        let bundle = read(path)
        entries.withLock { cache in
            if let bundle { cache.store(bundle, for: path, fingerprint: fingerprint) } else { cache.removeValue(for: path) }
        }
        return bundle
    }
}
