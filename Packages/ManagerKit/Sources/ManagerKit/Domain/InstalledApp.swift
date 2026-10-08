import Foundation

/// Wurzelordner, unter dem eine App gefunden wurde (Spec v3 §2).
public enum AppLocation: String, Hashable, Sendable, Codable {
    /// `/Applications` samt Unterordnern.
    case applications
    /// `~/Applications` samt Unterordnern.
    case userApplications
    /// Anderer Ort (derzeit nicht gescannt).
    case other
}

/// Herkunft einer App. `AppOriginDetector` prüft in dieser Reihenfolge: Homebrew-Cask, App Store, Apple, Web-App,
/// direkt. Den Entwicklernamen direkt geladener Apps trägt `SigningInfo.developerName` (Plan-Abweichung 2).
public enum AppOrigin: Hashable, Sendable, Codable {
    case appStore
    case homebrew(cask: String)
    case apple
    /// Über einen Browser installierte Web-App (PWA), ad hoc signiert oder unsigniert (`WebAppBrowser`).
    case webApp(browser: WebAppBrowser)
    case direct
    /// Nicht prüfbar: kein Signaturergebnis und kein anderer Beleg (Review M2). Der Scan ersetzt das durch die letzte
    /// bekannte Herkunft, sofern es eine gibt.
    case unverified
}

/// Browser, der eine Web-App (PWA) als App-Bundle angelegt hat.
public enum WebAppBrowser: String, Hashable, Sendable, Codable {
    /// „Zum Dock hinzufügen“ in Safari: Vorlagen-App (`LSTemplateApplication`) **ohne eigenes Programm** – macOS startet
    /// stattdessen Safaris Web-App-Host. Die Ad-hoc-Signatur des Bundles schützt keinen Code, es gibt keinen.
    case safari
    /// Chromium-Browser: App-Shim mit eigenem, nur ad hoc signiertem Programm (`app_mode_loader`), erkannt allein an der
    /// Bundle-ID – also fälschbar.
    case chrome, edge, brave

    /// Ob das Bundle eigenen Code mitbringt (alle außer Safari, siehe dort).
    public var bundlesOwnCode: Bool { self != .safari }
}

/// Architektur des Hauptprogramms laut Mach-O-Header (`MachOHeader`).
public enum AppArchitecture: String, Hashable, Sendable, Codable, CaseIterable {
    case appleSilicon, intel, universal, unknown
}

/// Wechsel der Team-ID gegenüber dem Vorgänger-Snapshot.
public struct TeamIDChange: Hashable, Sendable, Codable {
    public var previousTeamID: String
    /// Beginn des Scans, der den Wechsel erkannte.
    public var detectedAt: Date

    public init(previousTeamID: String, detectedAt: Date) {
        self.previousTeamID = previousTeamID
        self.detectedAt = detectedAt
    }
}

/// Warum `InstalledApp.signing`, Team-ID und Herkunft nicht aus einer Prüfung dieses Scans stammen (Review M2).
public enum SigningLimitation: Hashable, Sendable, Codable {
    /// Die Prüfung fiel aus (Zeitüberschreitung, erschöpfter `BlockingCallGuard`); kein früherer Wert bekannt.
    case notChecked
    /// Werte aus der Prüfung des Scans vom `verifiedAt` fortgeschrieben – das Hauptprogramm ist seitdem unverändert.
    case carriedForward(verifiedAt: Date)
    /// Das Hauptprogramm hat sich seit der letzten Prüfung geändert, die neue Signatur ist nicht prüfbar: Nichts wird
    /// übernommen, nur `lastKnownTeamID` bleibt als Vergleichsbasis.
    case changedSinceCheck
}

/// Eine installierte App (Quelle `SourceID.apps`, Spec v3 §2). Größe und „zuletzt benutzt“ stehen bewusst nicht hier,
/// sondern werden im Hintergrund nachgeladen und sind nie signifikant.
public struct InstalledApp: InventoryRecord, Codable {
    /// Kanonischer Pfad des Bundles; zugleich `id`.
    public var path: String
    public var bundleID: String?
    public var name: String
    /// `CFBundleShortVersionString`.
    public var shortVersion: String?
    /// `CFBundleVersion`.
    public var buildVersion: String?
    public var location: AppLocation
    public var origin: AppOrigin
    public var signing: SigningInfo
    public var architecture: AppArchitecture
    /// Letzter Wechsel der Team-ID, solange die App die damals neue Team-ID behält; nicht signifikant (der Wechsel
    /// selbst ist es über `signing.teamID`).
    public var teamIDChange: TeamIDChange?
    /// Team-ID des letzten Vorgängers mit Team-ID, solange die aktuelle Signatur keine trägt (ad hoc, unsigniert):
    /// Vergleichsbasis für `teamIDChange` (`Snapshot.carryingForwardAppState`); nicht signifikant.
    public var lastKnownTeamID: String?
    /// Ziel, wenn `path` ein symbolischer Link auf ein Bundle ist (Review M3): Grantry folgt ihm für keine Prüfung –
    /// Signatur, Herkunft und Architektur bleiben unbekannt, Metadaten stammen nur vom Link. Signifikant.
    public var symlinkTarget: String?
    /// Fingerabdruck des Hauptprogramms bei diesem Scan – verrät einen Austausch, auch wenn die Signaturprüfung ausfällt
    /// (Review M2); nicht signifikant.
    public var executableFingerprint: FileFingerprint?
    /// `nil`, wenn dieser Scan die Signatur geprüft hat; sonst der Grund, warum die Werte älter oder unbekannt sind.
    /// Nicht signifikant.
    public var signingLimitation: SigningLimitation?

    public init(
        path: String, bundleID: String?, name: String, shortVersion: String?, buildVersion: String?,
        location: AppLocation, origin: AppOrigin, signing: SigningInfo, architecture: AppArchitecture,
        teamIDChange: TeamIDChange? = nil, lastKnownTeamID: String? = nil, symlinkTarget: String? = nil,
        executableFingerprint: FileFingerprint? = nil, signingLimitation: SigningLimitation? = nil
    ) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.location = location
        self.origin = origin
        self.signing = signing
        self.architecture = architecture
        self.teamIDChange = teamIDChange
        self.lastKnownTeamID = lastKnownTeamID
        self.symlinkTarget = symlinkTarget
        self.executableFingerprint = executableFingerprint
        self.signingLimitation = signingLimitation
    }

    public var id: String { path }
    public var source: SourceID { .apps }

    /// Die App als vorhandene `AppIdentity` – für Symbol, Apple-Erkennung (`AppleComponent`) und Risikoregeln.
    public var identity: AppIdentity {
        AppIdentity(bundleID: bundleID, path: path, displayName: name, signing: signing, presence: .present)
    }

    /// Team-ID für den Vergleich mit einem Nachfolger: die aktuelle, sonst die zuletzt bekannte (`lastKnownTeamID`) –
    /// so bleibt ein Wechsel über eine Zwischenstufe ohne Team (ad hoc, unsigniert) erkennbar.
    public var referenceTeamID: String? { signing.teamID ?? lastKnownTeamID }

    /// „6.0 (600)“, bei gleichen Werten nur einer, sonst der vorhandene; `nil` ohne beide.
    public var versionText: String? {
        switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build: "\(short) (\(build))"
        case let (short?, _): short
        case let (nil, build?): build
        case (nil, nil): nil
        }
    }

    /// Signifikant (Spec v3 §2): Version, Team-ID (`referenceTeamID`, nur wenn beide bekannt), Signaturart und
    /// Architektur (jeweils ohne `unknown`), Symlink-Ziel. So erzeugt eine vorübergehend nicht prüfbare App kein
    /// Schein-Ereignis – und ein Wechsel über einen Scan ohne Prüfung (Team-ID `nil`, `lastKnownTeamID` = alte) bleibt
    /// beim nächsten geprüften Scan ein Ereignis, auch wenn der Snapshot ohne Prüfung nur im Speicher aufgefrischt wurde.
    public func hasSignificantChanges(comparedTo other: InstalledApp) -> Bool {
        shortVersion != other.shortVersion || buildVersion != other.buildVersion || symlinkTarget != other.symlinkTarget
            || Self.knownValuesDiffer(referenceTeamID, other.referenceTeamID)
            || Self.knownValuesDiffer(signing.kind.known, other.signing.kind.known)
            || Self.knownValuesDiffer(architecture.known, other.architecture.known)
    }

    /// `true` nur, wenn beide Werte bekannt sind und sich unterscheiden.
    private static func knownValuesDiffer<Value: Equatable>(_ lhs: Value?, _ rhs: Value?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }
}

extension SigningInfo.Kind {
    /// `nil` für `.unknown` (nicht prüfbar).
    var known: Self? { self == .unknown ? nil : self }
}

extension AppArchitecture {
    /// `nil` für `.unknown`.
    var known: Self? { self == .unknown ? nil : self }
}
