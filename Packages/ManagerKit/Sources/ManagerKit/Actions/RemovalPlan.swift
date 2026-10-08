import Foundation
import GrantryShared

/// Was „App entfernen“ bzw. „Aufräumen“ ausführt (Spec v3 §3).
///
/// Dateien sind die **unveränderten** Kandidaten der Suche (`LeftoverCandidate`, auch das App-Bundle selbst): Vor dem
/// Papierkorb prüft der `RemovalGuard`, dass jeder Eintrag noch dasselbe Objekt ist (`LeftoverCandidate.identity`), und
/// der `RemovalExecutor` gleicht den Plan mit einem frischen Scan ab (`OrphanRecheck` bzw. `AppRemovalRecheck`, #97,
/// #100): Der Plan hält den Stand vom Öffnen des Blatts fest, nicht den vom Ausführen.
public struct RemovalPlan: Hashable, Sendable, Identifiable {
    public static let cleanupID = "cleanup"

    /// Die zu entfernende App; `nil` beim Aufräumen (dann keine Freigabe für Apple-Kennungen).
    public let app: InstalledApp?
    public let grants: [PermissionGrant]
    public let autostartItems: [AutostartItem]
    public let files: [LeftoverCandidate]
    /// Reste-Orte, die die Suche nicht lesen konnte – dort ist „keine Reste“ nicht belegt.
    public let unreadableLocations: [String]
    /// Beim Aufräumen je Datei-Pfad, warum sie als Rest galt; vor dem Papierkorb gegen den aktuellen Stand geprüft
    /// (`OrphanRecheck`).
    let orphanClaims: [String: OrphanClaim]
    /// Berechtigungen und Autostart-Einträge, die auch eine weitere Installation derselben Bundle-ID träfen und trotz
    /// Hinweis bewusst gewählt wurden (`AppLinks.sharedIDs`, #97); andere gemeinsame Einträge überspringt der Executor.
    let acknowledgedSharedIDs: Set<String>
    /// Kanonische Pfade der weiteren Installationen derselben Bundle-ID, die bei der Auswahl bekannt waren
    /// (`AppLinks.otherInstallations`); kommt bis zur Ausführung eine hinzu, gilt keine Bestätigung mehr.
    let knownOtherInstallations: Set<String>

    /// Nur über `RemovalPlanning` (Kandidaten unverändert aus der Suche).
    init(
        app: InstalledApp?, grants: [PermissionGrant], autostartItems: [AutostartItem], files: [LeftoverCandidate],
        unreadableLocations: [String] = [], orphanClaims: [String: OrphanClaim] = [:], acknowledgedSharedIDs: Set<String> = [],
        knownOtherInstallations: Set<String> = []
    ) {
        self.app = app
        self.grants = grants
        self.autostartItems = autostartItems
        self.files = files
        self.unreadableLocations = unreadableLocations
        self.orphanClaims = orphanClaims
        self.acknowledgedSharedIDs = acknowledgedSharedIDs
        self.knownOtherInstallations = knownOtherInstallations
    }

    /// `ActionRunner.runningRecordID` während der Ausführung.
    public var id: String { app?.id ?? Self.cleanupID }
    public var isEmpty: Bool { grants.isEmpty && autostartItems.isEmpty && files.isEmpty }
    /// Summe der vollständig gezählten Größen.
    public var knownSize: Int64 { RemovalSize(files).known }
}

/// Größensumme mehrerer Kandidaten: gezählt, nicht lesbar (`FileSize.unreadable`), nicht gemessen.
struct RemovalSize {
    let known: Int64
    let unreadable: Int
    let unknown: Int

    init(_ files: [LeftoverCandidate]) {
        known = files.compactMap(\.size.bytes).reduce(0, +)
        unreadable = files.count { $0.size == .unreadable }
        unknown = files.count { $0.size == .unknown }
    }

    /// „1,2 GB“, „mindestens 1,2 GB“, „mindestens 1,2 GB, 2 Größen nicht lesbar“, „Größe unbekannt“, „Größe nicht lesbar“.
    var text: String {
        let complete = unreadable == 0 && unknown == 0
        if complete { return AppTexts.formattedSize(known) }
        if known == 0 { return unknown == 0 ? "Größe nicht lesbar" : "Größe unbekannt" }
        let minimum = "mindestens \(AppTexts.formattedSize(known))"
        guard unreadable > 0 else { return minimum }
        return minimum + ", " + (unreadable == 1 ? "1 Größe" : "\(unreadable) Größen") + " nicht lesbar"
    }
}

/// Sonderfälle beim Entfernen (Spec v3 §3).
public enum RemovalRoute: Hashable, Sendable {
    case removable
    /// Grantry entfernt die App nicht selbst; der Befehl zum Kopieren.
    case homebrew(command: String)
    /// Die laufende Grantry: nur über „Grantry deinstallieren …“ (`SelfUninstaller`), nie über den `RemovalExecutor`.
    case grantryItself
    /// Eine weitere Kopie von Grantry an anderem Ort: Sie teilt Bundle-ID, Berechtigungen und Daten mit der laufenden –
    /// weder `SelfUninstaller` (meldete die Dienste der laufenden ab) noch `RemovalExecutor` dürfen sie entfernen.
    case otherGrantryCopy

    /// Grantry erkennt sich am Pfad des laufenden Bundles, nicht an der Bundle-ID – sonst träfe „Grantry deinstallieren
    /// …“ womöglich eine andere Kopie.
    public static func route(
        for app: InstalledApp, ownBundleID: String = GrantryIdentity.appBundleID, ownPath: String = Bundle.main.bundlePath
    ) -> RemovalRoute {
        if app.path == ownPath { return .grantryItself }
        if app.bundleID == ownBundleID {
            return resolvedPath(app.path) == resolvedPath(ownPath) ? .grantryItself : .otherGrantryCopy
        }
        if case .homebrew(let cask) = app.origin { return .homebrew(command: "brew uninstall --cask \(shellQuoted(cask))") }
        return .removable
    }

    /// Warum Grantry nichts anfasst; `nil` bei `.removable`.
    public var reason: String? {
        switch self {
        case .removable: nil
        case .homebrew(let command): "Über Homebrew installiert – bitte „\(command)“ im Terminal ausführen."
        case .grantryItself: "Grantry entfernt sich nur über „Grantry deinstallieren …“."
        case .otherGrantryCopy: "Weitere Kopie von Grantry – sie teilt Berechtigungen und Daten mit der laufenden Grantry. Bitte im Finder in den Papierkorb legen."
        }
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Cask-Namen bestehen aus `[a-z0-9@._+-]`; alles andere in einfache Anführungszeichen.
    private static func shellQuoted(_ word: String) -> String {
        let plain = word.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "@._+-".contains($0)) }
        return plain && !word.isEmpty ? word : "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Plan aus der Auswahl des Nutzers (IDs: Kandidaten-Pfad, `PermissionGrant.id`, `AutostartItem.id`).
public enum RemovalPlanning {
    /// Für `app`: ausgewählte Kandidaten der Reste-Suche (unverändert) sowie Berechtigungen und Autostart-Einträge der App
    /// (`AppLinks`), soweit die `ActionPolicy` sie zulässt. Gewählte Einträge, die auch eine weitere Installation derselben
    /// Bundle-ID träfen, gelten als bewusst gewählt (`acknowledgedSharedIDs`); Konflikte kennt `AppLinks` gar nicht.
    public static func plan(
        for app: InstalledApp, leftovers: LeftoverScanResult, snapshot: Snapshot, selection: Set<String>,
        policy: ActionPolicy = ActionPolicy()
    ) -> RemovalPlan {
        let links = AppLinks.of(app, in: snapshot)
        return RemovalPlan(
            app: app,
            grants: links.grants.filter { selection.contains($0.id) && policy.availability(for: $0) == .available },
            autostartItems: links.autostartItems.filter { selection.contains($0.id) && policy.availability(for: $0) == .available },
            files: leftovers.candidates.filter { selection.contains($0.path) },
            unreadableLocations: leftovers.unreadableLocations,
            acknowledgedSharedIDs: links.sharedIDs.intersection(selection),
            knownOtherInstallations: Set(links.otherInstallations.map { InstallationIndex.canonical($0.path) })
        )
    }

    /// Fürs Aufräumen: ausgewählte Kandidaten aller Gruppen und ausgewählte verwaiste Autostart-Einträge, samt Begründung
    /// je Fund für die Prüfung vor dem Papierkorb. Verwaiste Berechtigungen bleiben Hinweis (`tccutil` braucht die
    /// installierte App).
    public static func plan(cleanup result: OrphanScanResult, selection: Set<String>) -> RemovalPlan {
        let leftovers = result.leftovers
        return RemovalPlan(
            app: nil, grants: [],
            autostartItems: result.autostartItems.filter { selection.contains($0.id) },
            files: leftovers.candidates.filter { selection.contains($0.path) },
            unreadableLocations: leftovers.unreadableLocations,
            orphanClaims: result.claims.filter { selection.contains($0.key) }
        )
    }
}

/// Ergebnis je Eintrag (Spec v3 §3 Schritt 5).
public struct RemovalReport: Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        case file(LeftoverCandidate)
        case grant(PermissionGrant)
        case autostartItem(AutostartItem)
    }

    public enum Result: Hashable, Sendable {
        case done
        case doneWithWarning(String)
        case failed(String)
        case skipped(String)

        public var isDone: Bool {
            switch self {
            case .done, .doneWithWarning: true
            case .failed, .skipped: false
            }
        }

        /// Grund bzw. Warnung; `nil` bei `.done`.
        public var reason: String? {
            switch self {
            case .done: nil
            case .doneWithWarning(let text), .failed(let text), .skipped(let text): text
            }
        }
    }

    public struct Entry: Hashable, Sendable {
        public let subject: Subject
        public let result: Result

        public init(subject: Subject, result: Result) {
            self.subject = subject
            self.result = result
        }
    }

    public var entries: [Entry]
    /// Keine Automation-Freigabe für den Finder – nichts wurde verändert.
    public var automationDenied: Bool

    public init(entries: [Entry], automationDenied: Bool = false) {
        self.entries = entries
        self.automationDenied = automationDenied
    }

    /// Alle Einträge des Plans mit demselben Grund übersprungen (in Ausführungsreihenfolge).
    public static func skipping(_ plan: RemovalPlan, reason: String, automationDenied: Bool = false) -> RemovalReport {
        RemovalReport(
            entries: plan.grants.map { Entry(subject: .grant($0), result: .skipped(reason)) }
                + plan.autostartItems.map { Entry(subject: .autostartItem($0), result: .skipped(reason)) }
                + plan.files.map { Entry(subject: .file($0), result: .skipped(reason)) },
            automationDenied: automationDenied
        )
    }
}
