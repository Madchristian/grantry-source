import AppKit
import Synchronization

/// Löst Bundle-IDs und Pfade zu `AppIdentity` auf.
public protocol AppResolving: Sendable {
    /// Sucht die installierte App zu `bundleID`. Findet Launch Services sie nicht, lässt sich ihr Fehlen nicht
    /// beweisen (Systemerweiterungen, eingebettete Helfer und XPC-Dienste sind dort nie registriert): Kennt auch
    /// Spotlight kein solches Bundle, gilt sie als `probablyMissing`, sonst als `unknown`.
    func resolve(bundleID: String) async -> AppIdentity
    /// Beschreibt das App-Bundle oder Programm unter `path`. `missing` nur bei belegtem Fehlen, `unknown` z. B.
    /// ohne Leserecht auf ein Elternverzeichnis (siehe `Presence.init(ofItemAt:)`).
    func resolve(path: String) async -> AppIdentity
}

/// Antwort von Launch Services auf die Frage nach einer Bundle-ID.
public enum BundleLocation: Hashable, Sendable {
    case found(path: String)
    /// Launch Services kennt die Bundle-ID nicht.
    case notRegistered
    /// Keine Antwort (Zeitüberschreitung) – über die App lässt sich nichts sagen.
    case unavailable
}

/// Findet den Installationspfad zu einer Bundle-ID.
public protocol BundleLocating: Sendable {
    func location(ofBundleID bundleID: String) -> BundleLocation
}

/// Implementierung über Launch Services (`NSWorkspace.urlForApplication`) – die einzige Stelle, an der Grantry beim
/// Scannen Launch Services fragt: TCC-Berechtigungen nennen oft nur die Bundle-ID, und nur Launch Services kennt deren
/// Installationsort (auch außerhalb von `/Applications`). Die Abfrage liest die Datenbank des `lsd`, öffnet aber keine
/// Bundle-Dateien; gegen einen hängenden `lsd` läuft sie mit Frist über einen eigenen Guard
/// (`BlockingCallGuard.launchServices`) und ergibt danach `.unavailable`.
public struct WorkspaceBundleLocator: BundleLocating {
    /// Frist je Abfrage – üblich sind Millisekunden.
    static let timeout: Duration = .seconds(5)

    public init() {}

    public func location(ofBundleID bundleID: String) -> BundleLocation {
        let path = BlockingCallGuard.launchServices.run(timeout: Self.timeout) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        }
        switch path {
        case .some(.some(let path)): return .found(path: path)
        case .some(.none): return .notRegistered
        case .none: return .unavailable
        }
    }
}

/// Standard-Resolver mit Cache pro Pfad. Ein Eintrag gilt, solange sich der Fingerabdruck des Ziels nicht ändert
/// (siehe `FileFingerprint`): Ein aktualisiertes oder ausgetauschtes Programm wird also neu geprüft. Symlinks werden
/// aufgelöst; `AppIdentity.path` bleibt der angefragte Pfad. Fehlende oder nicht prüfbare Pfade werden nicht
/// zwischengespeichert.
///
/// Metadaten liest der Resolver direkt aus `Contents/Info.plist` statt über `Bundle`, weil Foundation
/// `Bundle`-Instanzen prozessweit zwischenspeichert und Änderungen nach einem Update sonst nicht sähe; den Namen liest
/// `names` (Standard `BundleNameReader`, ohne Launch Services). Eine Zeitüberschreitung der Signaturprüfung wird nicht
/// gemerkt (`SigningInspection.timedOut`).
public actor AppResolver: AppResolving {
    private let locator: any BundleLocating
    private let inspector: any SigningInspecting
    private let names: any AppNameReading
    private let spotlight: any BundleSpotlightLocating
    private let now: @Sendable () -> Date
    private let cache = Mutex(FingerprintCache<AppIdentity>())
    private let queue = BlockingWorkQueue(label: "app-resolution")
    private var spotlightCache: ExpiringTaskCache<String, SpotlightLookup>

    /// Wie lange eine Spotlight-Anfrage ohne Antwort (`unavailable`) gemerkt wird: kurz genug für einen neuen
    /// Versuch beim nächsten Scan, lang genug, dass ein hängendes `mdfind` einen Scan nicht je Grant ausbremst.
    static let unavailableSpotlightTTL: TimeInterval = 60

    /// - Parameter spotlightTTL: Wie lange (Sekunden) eine Spotlight-Antwort je Bundle-ID gilt; ohne Antwort
    ///   (`unavailable`) höchstens `unavailableSpotlightTTL`. Launch Services wird trotzdem bei jeder Auflösung
    ///   gefragt – eine neu installierte App fällt also sofort auf.
    public init(
        locator: any BundleLocating = WorkspaceBundleLocator(),
        inspector: any SigningInspecting = SecuritySigningInspector(),
        spotlight: any BundleSpotlightLocating = SpotlightBundleLocator(),
        names: any AppNameReading = BundleNameReader(),
        spotlightTTL: TimeInterval = 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locator = locator
        self.inspector = inspector
        self.names = names
        self.spotlight = spotlight
        self.now = now
        spotlightCache = ExpiringTaskCache { lookup in
            lookup == .unavailable ? min(spotlightTTL, Self.unavailableSpotlightTTL) : spotlightTTL
        }
    }

    public func resolve(bundleID: String) async -> AppIdentity {
        let presence: Presence
        switch await queue.run({ [locator] in locator.location(ofBundleID: bundleID) }) {
        case .found(let path):
            var identity = await resolve(path: path)
            identity.bundleID = bundleID
            return identity
        case .notRegistered:
            presence = await spotlightLookup(bundleID) == .notFound ? .probablyMissing : .unknown
        case .unavailable:
            presence = .unknown
        }
        return AppIdentity(bundleID: bundleID, path: nil, displayName: bundleID, signing: .unknown, presence: presence)
    }

    public func resolve(path: String) async -> AppIdentity {
        await queue.run { self.resolveExisting(path: path) }
    }

    /// Spotlight-Antwort zu `bundleID`, höchstens einmal je Gültigkeitsdauer abgefragt; gleichzeitige Auflösungen
    /// derselben ID teilen sich eine Anfrage. Ein Treffer ergibt nur `unknown`,
    /// nicht `present`: Das gefundene Bundle kann eine veraltete Kopie sein (Papierkorb, Disk-Image, eine zur
    /// Deinstallation vorgemerkte Systemerweiterung), und ohne Launch Services fehlt die Gewissheit, welches TCC meint.
    private func spotlightLookup(_ bundleID: String) async -> SpotlightLookup {
        let spotlight = spotlight
        let task = spotlightCache.task(for: bundleID, now: now()) { await spotlight.lookup(bundleID: bundleID) }
        let lookup = await task.value
        spotlightCache.finish(bundleID, task: task, value: lookup, now: now())
        return lookup
    }

    /// Gemeinsamer Kern auf der seriellen Queue: kein Suspensionspunkt zwischen Cache-Lesen und -Schreiben, auch
    /// bei gleichzeitigen Auflösungen desselben Pfads. Die kurzen Cache-Sperren umfassen nie die Signaturprüfung.
    private nonisolated func resolveExisting(path: String) -> AppIdentity {
        let target = FileFingerprint.target(of: path)
        let presence = Presence(ofItemAt: path)
        guard presence == .present, let fingerprint = FileFingerprint(of: target) else {
            cache.withLock { $0.removeValue(for: path) }
            let unresolved: Presence = presence == .present ? .unknown : presence
            return AppIdentity(bundleID: nil, path: path, displayName: BundleNameReader.fallbackName(of: path),
                               signing: .unknown, presence: unresolved)
        }
        if let identity = cache.withLock({ $0.value(for: path, matching: fingerprint) }) { return identity }

        let info = FileFingerprint.isAppBundle(target) ? Self.infoDictionary(ofBundleAt: target) : [:]
        let signing = inspector.inspection(ofPath: target)
        let identity = AppIdentity(
            bundleID: info["CFBundleIdentifier"] as? String,
            path: path,
            displayName: FileFingerprint.isAppBundle(target)
                ? names.name(ofBundleAt: target, info: info)
                : BundleNameReader.fallbackName(of: path),
            signing: signing.info,
            presence: .present
        )
        // Eine Zeitüberschreitung ist kein Ergebnis (Review M1): nicht merken, die nächste Auflösung prüft erneut.
        if signing.isConclusive { cache.withLock { $0.store(identity, for: path, fingerprint: fingerprint) } }
        return identity
    }

    /// Inhalt von `Contents/Info.plist`, leer, wenn sie fehlt, unlesbar oder keine reguläre Datei ist – gelesen ohne
    /// Blockieren (`BundleLayout.info`), eine FIFO als Info.plist hält den Resolver nicht an.
    private static func infoDictionary(ofBundleAt path: String) -> [String: Any] {
        BundleLayout(path: path).info
    }
}
