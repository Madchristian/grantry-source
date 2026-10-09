import Foundation

/// Berechtigungen und Autostart-Einträge einer App – über Bundle-ID oder Bundle-Pfad (v1-Zuordnung über
/// `PermissionGrant.client` bzw. `AutostartItem.owner`).
///
/// Ist dieselbe Bundle-ID mehrfach installiert (#97), entscheiden die belastbaren Pfade eines Eintrags (`InstallationIndex`,
/// Programmpfad bzw. Pfad-Client): Liegt einer in einer **anderen** installierten App, gehört der Eintrag nicht hierher
/// (Konflikt statt Treffer). Was nur über die Bundle-ID zugeordnet ist, träfe beide Installationen und steht in `sharedIDs`.
public struct AppLinks: Hashable, Sendable {
    public let grants: [PermissionGrant]
    public let autostartItems: [AutostartItem]
    /// IDs (`PermissionGrant.id`, `AutostartItem.id`) der Einträge mit mehrdeutiger oder nicht belegter Eigentümerschaft –
    /// nicht vorausgewählt, nur bewusst wählbar.
    public let sharedIDs: Set<String>
    /// Weitere installierte Apps mit derselben Bundle-ID.
    public let otherInstallations: [InstalledApp]

    public init(
        grants: [PermissionGrant], autostartItems: [AutostartItem], sharedIDs: Set<String> = [],
        otherInstallations: [InstalledApp] = []
    ) {
        self.grants = grants
        self.autostartItems = autostartItems
        self.sharedIDs = sharedIDs
        self.otherInstallations = otherInstallations
    }

    public static func of(_ app: InstalledApp, in snapshot: Snapshot) -> AppLinks {
        let installations = InstallationIndex(snapshot.installedApps)
        return installations.links(of: app, grants: snapshot.grants, autostartItems: snapshot.autostartItems)
    }

    /// Wie `of(_:in:)` für alle Apps auf einmal, je `InstalledApp.id` – mit einem Index statt eines Durchlaufs je App.
    static func index(_ apps: [InstalledApp], in snapshot: Snapshot) -> [String: AppLinks] {
        let installations = InstallationIndex(snapshot.installedApps)
        let grants = OwnerLookup(snapshot.grants) { $0.client }
        let items = OwnerLookup(snapshot.autostartItems) { $0.owner }
        return Dictionary(
            apps.map { app in
                (app.id, installations.links(of: app, grants: grants.matching(app), autostartItems: items.matching(app)))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// Wie ein Eintrag zu einer App steht (#97).
enum LinkAssignment: Hashable, Sendable {
    /// Weder Bundle-ID noch Bundle-Pfad des Eigentümers passen.
    case unrelated
    /// Gehört nur zu dieser Installation.
    case exclusive
    /// Passt zur App, ist aber wegen weiterer Installationen oder fehlendem Signaturbeleg nicht eindeutig.
    case shared
    /// Ein belastbarer Pfad liegt in einer anderen App (auch außerhalb des Inventars) – gehört nicht dazu.
    case conflict

    /// Gehört zur App (allein oder gemeinsam mit weiteren Installationen).
    var belongs: Bool { self == .exclusive || self == .shared }
}

/// Installierte Apps nach Pfad und Bundle-ID – ordnet Berechtigungen und Autostart-Einträge einer Installation zu.
///
/// Belastbar ist nur ein Pfad, den der Eintrag selbst nennt (sein **Anker**): der Programmpfad eines Autostart-Eintrags
/// bzw. ein TCC-Client, der ein Pfad ist. Der Eigentümerpfad allein kann aus der Auflösung der Bundle-ID über Launch
/// Services stammen (`AppResolver.resolve(bundleID:)`) und zeigt dann auf irgendeine der Installationen – er ordnet zu,
/// begründet aber weder Konflikt noch Eindeutigkeit. Pfade werden kanonisch verglichen (`AppleComponent.canonicalPath`),
/// Bundle-IDs ohne Groß-/Kleinschreibung.
struct InstallationIndex {
    private let byPath: [String: InstalledApp]
    private let byBundleID: [String: [InstalledApp]]

    init(_ apps: [InstalledApp]) {
        byPath = Dictionary(apps.map { (Self.canonical($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        byBundleID = Dictionary(grouping: apps.filter { $0.bundleID != nil }) { Self.key($0.bundleID) ?? "" }
    }

    /// Die installierte App an `path` (kanonisch verglichen); `nil`, wenn dort keine liegt.
    func installation(at path: String) -> InstalledApp? {
        byPath[Self.canonical(path)]
    }

    /// Weitere installierte Apps mit der Bundle-ID von `app`.
    func otherInstallations(of app: InstalledApp) -> [InstalledApp] {
        guard let bundleID = Self.key(app.bundleID) else { return [] }
        let path = Self.canonical(app.path)
        return byBundleID[bundleID, default: []].filter { Self.canonical($0.path) != path }
    }

    func links(of app: InstalledApp, grants: [PermissionGrant], autostartItems: [AutostartItem]) -> AppLinks {
        var sharedIDs: Set<String> = []
        func keep(_ assignment: LinkAssignment, id: String) -> Bool {
            if assignment == .shared { sharedIDs.insert(id) }
            return assignment.belongs
        }
        let grants = grants.filter { keep(assignment(of: $0, to: app), id: $0.id) }
        let items = autostartItems.filter { keep(assignment(of: $0, to: app), id: $0.id) }
        return AppLinks(grants: grants, autostartItems: items, sharedIDs: sharedIDs,
                        otherInstallations: otherInstallations(of: app))
    }

    /// Anker einer Berechtigung: der TCC-Client selbst, wenn er ein Pfad ist; ein Client nach Bundle-ID gilt für jede
    /// Installation mit dieser Bundle-ID (`tccutil` setzt nur nach Bundle-ID zurück).
    func assignment(of grant: PermissionGrant, to app: InstalledApp) -> LinkAssignment {
        assignment(owner: grant.client, anchor: grant.clientID.hasPrefix("/") ? grant.clientID : nil,
                   requiringSameTeam: true, to: app)
    }

    /// Anker eines Autostart-Eintrags: sein Programmpfad.
    func assignment(of item: AutostartItem, to app: InstalledApp) -> LinkAssignment {
        item.owner.map { assignment(owner: $0, anchor: item.program, requiringSameTeam: item.domain == .system, to: app) }
            ?? .unrelated
    }

    private func assignment(
        owner: AppIdentity, anchor: String?, requiringSameTeam: Bool, to app: InstalledApp
    ) -> LinkAssignment {
        let appPath = Self.canonical(app.path)
        let byBundleID = Self.key(app.bundleID) != nil && Self.key(owner.bundleID) == Self.key(app.bundleID)
        guard byBundleID || owner.path.map(Self.canonical) == appPath else { return .unrelated }
        let anchorApp = anchor.flatMap(bundlePath(containing:))
        if let anchorApp, anchorApp != appPath { return .conflict }
        if requiringSameTeam && !Self.hasSameVerifiedTeam(app.signing, owner.signing) { return .shared }
        guard !otherInstallations(of: app).isEmpty else { return .exclusive }
        return anchorApp == nil ? .shared : .exclusive
    }

    /// Nur zertifikatsgebundene, nicht leere Team-IDs belegen denselben Hersteller. Ad-hoc-Signaturen können
    /// Metadaten selbst wählen; zwei fehlende Team-IDs sind ebenfalls kein Herkunftsbeleg.
    private static func hasSameVerifiedTeam(_ app: SigningInfo, _ owner: SigningInfo) -> Bool {
        let verifiedKinds: Set<SigningInfo.Kind> = [.developerID, .appStore, .development]
        guard verifiedKinds.contains(app.kind), verifiedKinds.contains(owner.kind),
              let team = app.teamID, !team.isEmpty else { return false }
        return team == owner.teamID
    }

    /// Innerste installierte App am Anker; ohne Inventartreffer das nächste `.app`-Bundle. Eingebettete Helfer
    /// bleiben Teil ihrer inventarisierten Haupt-App. Jede Stufe wird kanonisiert, auch unter einem Symlink.
    private func bundlePath(containing path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var candidate = Self.canonical(path)
        var unlistedBundle: String?
        while candidate.count > 1 {
            let canonical = Self.canonical(candidate)
            if let app = byPath[canonical] { return Self.canonical(app.path) }
            if unlistedBundle == nil && (canonical as NSString).pathExtension.lowercased() == "app" {
                unlistedBundle = canonical
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return unlistedBundle
    }

    static func canonical(_ path: String) -> String {
        AppleComponent.canonicalPath(path) ?? path
    }

    static func key(_ bundleID: String?) -> String? {
        bundleID?.lowercased()
    }
}

/// Einträge nach Bundle-ID und Pfad ihrer App (Vorauswahl für `InstallationIndex.links`, Schlüssel wie dort: Pfad kanonisch,
/// Bundle-ID ohne Groß-/Kleinschreibung), Reihenfolge wie im Snapshot.
private struct OwnerLookup<Element> {
    private let elements: [Element]
    private let byBundleID: [String: [Int]]
    private let byPath: [String: [Int]]

    init(_ elements: [Element], owner: (Element) -> AppIdentity?) {
        self.elements = elements
        var byBundleID: [String: [Int]] = [:], byPath: [String: [Int]] = [:]
        for (index, element) in elements.enumerated() {
            guard let identity = owner(element) else { continue }
            if let bundleID = InstallationIndex.key(identity.bundleID) { byBundleID[bundleID, default: []].append(index) }
            if let path = identity.path { byPath[InstallationIndex.canonical(path), default: []].append(index) }
        }
        self.byBundleID = byBundleID
        self.byPath = byPath
    }

    func matching(_ app: InstalledApp) -> [Element] {
        var indices = Set(byPath[InstallationIndex.canonical(app.path)] ?? [])
        if let bundleID = InstallationIndex.key(app.bundleID) { indices.formUnion(byBundleID[bundleID] ?? []) }
        return indices.sorted().map { elements[$0] }
    }
}
