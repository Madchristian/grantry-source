import Foundation
import os
import Synchronization

/// Symbol einer App oder eines Programms, ohne Launch Services ermittelt (Review H1).
public enum AppIcon: Hashable, Sendable {
    /// Inhalt der `.icns`-Datei des Bundles.
    case icns(Data)
    /// Generisches App-Symbol: Bundle ohne lesbare `.icns`-Datei.
    case genericApplication
    /// Generisches Programm-Symbol: einzelne Datei.
    case genericExecutable
    /// Nichts vorhanden.
    case missing
}

/// Ermittelt das Symbol zu einem Pfad.
public protocol AppIconReading: Sendable {
    func icon(atPath path: String) -> AppIcon
}

/// Symbol aus den Bundle-Dateien statt `NSWorkspace.icon(forFile:)` (Review H1): Launch Services registrierte dabei das
/// Bundle, der `lsd` des Nutzers öffnete `Info.plist` und Hauptprogramm und hing an einer FIFO dauerhaft.
///
/// - Bundle (Verzeichnis): `CFBundleIconFile`, sonst `CFBundleIconName` aus der `Info.plist` (`BundleLayout.info`), mit
///   oder ohne Endung `.icns`, aus `Resources/` – nur als reguläre Datei bis `maximumIconLength` und nur mit
///   `icns`-Kennung (`FileType.contentsOfRegularFile`). Sonst das generische App-Symbol.
/// - Apps nur mit Asset-Katalog (`Assets.car`, ohne `.icns`) und iOS-Apps im Wrapper (PNG-Symbole im inneren Bundle)
///   zeigen bewusst das generische App-Symbol: Den Katalog zu lesen hieße, ein privates Format zu parsen.
/// - Einzelne Datei: generisches Programm-Symbol; geöffnet wird sie nicht.
/// - Symlinks: verfolgt nur ins versiegelte System (`/Applications/Safari.app` → Cryptex); sonst generisch – wie im
///   App-Inventar folgt Grantry fremden Links nicht.
public struct BundleIconReader: AppIconReading {
    /// Höchstgröße einer `.icns`-Datei; die größte unter `/Applications` gemessene hat 2,1 MB.
    static let maximumIconLength = 4 << 20
    private static let magic = Data("icns".utf8)

    public init() {}

    public func icon(atPath path: String) -> AppIcon {
        guard let link = FileType.linkStatus(of: path) else { return .missing }
        guard let info = FileType.status(of: path) else { return .missing }
        guard FileType.isDirectory(info) else { return .genericExecutable }
        if FileType.isSymbolicLink(link), AppleComponent.canonicalPath(path).map(AppleComponent.isSystemPath) != true {
            return .genericApplication
        }
        guard WrapperLayout(path: path) == nil else { return .genericApplication }
        let layout = BundleLayout(path: path)
        let plist = layout.info
        for key in ["CFBundleIconFile", "CFBundleIconName"] {
            guard let name = plist[key] as? String, let data = Self.icns(named: name, in: layout.resourcesDirectory) else { continue }
            return .icns(data)
        }
        return .genericApplication
    }

    /// `Resources/<name>[.icns]` als reguläre Datei mit `icns`-Kennung; `nil` für Namen, die aus `Resources/`
    /// hinausführen könnten (`/`, `.`, `..`), zu große oder andere Dateien.
    private static func icns(named name: String, in resources: String) -> Data? {
        let file = name.lowercased().hasSuffix(".icns") ? name : name + ".icns"
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              let data = FileType.contentsOfRegularFile(atPath: resources + "/" + file, maximumLength: maximumIconLength + 1),
              data.count <= maximumIconLength, data.starts(with: magic) else { return nil }
        return data
    }
}

/// Ein geladenes Symbol samt Revision: Die Revision ändert sich, sobald das Symbol neu gelesen wurde – Anzeigen können
/// ihr dekodiertes Bild so behalten, solange sie gleich bleibt.
public struct LoadedAppIcon: Hashable, Sendable {
    public let icon: AppIcon
    public let revision: UInt64
}

/// Lädt Symbole auf eigener serieller Queue (nie im kooperativen Pool, nie auf dem Main Actor) und merkt sie je Pfad
/// und `FileFingerprint` – ein Update der App liest neu. Fehlende Pfade werden nicht gemerkt.
///
/// Jedes Symbol hat eine Frist (`timeout`, `BlockingCallGuard.icons`, Review N5): Hängt das Lesen (etwa auf einem
/// nicht antwortenden Volume), gilt das Symbol als generisch (Revision 0, nicht gemerkt), und die Queue lädt die
/// übrigen weiter.
public final class AppIconLoader: Sendable {
    public static let shared = AppIconLoader()
    /// Frist je Symbol – üblich sind Millisekunden.
    static let defaultTimeout: Duration = .seconds(5)

    private struct State {
        var cache = FingerprintCache<LoadedAppIcon>()
        var nextRevision: UInt64 = 1
    }

    private let reader: any AppIconReading
    private let queue = DispatchQueue(label: "de.cstrube.Grantry.app-icons", qos: .utility)
    private let state = Mutex(State())
    private let timeout: Duration
    private let callGuard: BlockingCallGuard

    public convenience init(reader: any AppIconReading = BundleIconReader()) {
        self.init(reader: reader, timeout: Self.defaultTimeout, callGuard: .icons)
    }

    init(reader: any AppIconReading, timeout: Duration, callGuard: BlockingCallGuard) {
        self.reader = reader
        self.timeout = timeout
        self.callGuard = callGuard
    }

    public func icon(forPath path: String) async -> LoadedAppIcon {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.loadNow(path)) }
        }
    }

    private func loadNow(_ path: String) -> LoadedAppIcon {
        guard let fingerprint = FileFingerprint(of: path) else {
            state.withLock { $0.cache.removeValue(for: path) }
            return LoadedAppIcon(icon: read(path) ?? .genericApplication, revision: 0)
        }
        if let cached = state.withLock({ $0.cache.value(for: path, matching: fingerprint) }) { return cached }
        guard let icon = read(path) else { return LoadedAppIcon(icon: .genericApplication, revision: 0) }
        return state.withLock { state in
            let loaded = LoadedAppIcon(icon: icon, revision: state.nextRevision)
            state.nextRevision += 1
            state.cache.store(loaded, for: path, fingerprint: fingerprint)
            return loaded
        }
    }

    /// Symbol von `path`; `nil` nach Ablauf der Frist.
    private func read(_ path: String) -> AppIcon? {
        let reader = reader
        guard let icon = callGuard.run(timeout: timeout, { reader.icon(atPath: path) }) else {
            Self.logger.error("Symbol von \(PathDisplay.abbreviatingHome(path), privacy: .public) nicht lesbar (Zeitüberschreitung)")
            return nil
        }
        return icon
    }

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "icons")
}
