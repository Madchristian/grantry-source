import Foundation

/// Prüft einen App-Entfernungsplan unmittelbar vor dem Eingriff gegen den **aktuellen** Snapshot – das Gegenstück zu
/// `OrphanRecheck` fürs Aufräumen. Das Blatt hält den Stand vom Öffnen fest; bis zur Ausführung kann eine weitere App
/// installiert oder die App am Ort ersetzt worden sein.
///
/// - Dateien (#100): jeder Rest wird mit den Regeln der Suche (`LeftoverMatcher`) gegen die jetzt installierten Apps
///   neu zugeordnet. Gehört er nicht mehr zur App (eine länger benannte Bundle-ID besitzt ihn jetzt) oder ist er nicht
///   mehr exklusiv (Gruppencontainer eines Teams, das inzwischen eine weitere App hat; Bundle-ID-Treffer bei einer neuen
///   Installation derselben Bundle-ID), bleibt er liegen. Ein bewusst gewählter unsicherer Rest läuft nur, solange sein
///   Hinweis unverändert ist oder wegfällt – ein geänderter Hinweis sperrt, auch wenn er nur kürzer wurde; gleicher
///   Hinweis heißt gleiche Namen, nicht dieselben Apps. Bewusst konservativ ist auch: Taucht im frischen Scan eine App
///   ohne prüfbare Team-ID auf, gelten Team-Gruppencontainer als unsicher und bleiben liegen. Für die Zuordnung zählt die
///   App, die jetzt am Ort liegt (aktuelle Team-ID, aktueller Name). Das App-Bundle selbst wird nicht neu zugeordnet; es
///   prüfen die Ersetzt-Prüfung unten und der `RemovalGuard` (Ort und Objekt).
/// - Berechtigungen und Autostart-Einträge (#97): Zuordnung über `InstallationIndex`; ein neuer Konflikt oder eine bei der
///   Auswahl unbekannte weitere Installation derselben Bundle-ID sperrt auch bestätigte Einträge.
/// - Liegt am Ort der App jetzt eine App mit anderer Bundle-ID oder (beide bekannt) anderer Team-ID, passt der Plan nicht
///   mehr: alles bleibt liegen.
/// - Ohne aktuellen Snapshot bzw. ohne belastbares App-Inventar bleibt alles liegen – auch wenn der Scan beim Beenden der
///   App (`ActionCoordinator.drain()`) oder durch Abbruch des Plans abgekürzt wurde.
struct AppRemovalRecheck {
    static let missingInventoryReason = "App-Inventar liegt nicht vor – nicht angefasst."
    static let unknownLocationReason = "Kein Reste-Ort der Suche – nicht angefasst."

    /// Gehört nach dem aktuellen Stand nicht (mehr) zu dieser App – ein Pfad zeigt auf eine andere installierte App,
    /// oder eine andere Bundle-ID besitzt den Rest jetzt.
    static func otherOwnerReason(_ app: InstalledApp) -> String {
        "Gehört nach aktuellem Stand nicht zu „\(app.name)“ – nicht angefasst."
    }

    /// Weitere Installationen derselben Bundle-ID, die der Eintrag ebenfalls träfe.
    static func sharedReason(with others: [InstalledApp]) -> String {
        let names = others.map { OwnershipNote.installation($0, home: NSHomeDirectory()) }
        return "Träfe auch \(names.joined(separator: ", ")) mit derselben Bundle-ID – nicht angefasst."
    }

    /// Ein Rest ist nach dem aktuellen Stand nicht mehr eindeutig; `note` ist der Hinweis der Suche (`LeftoverMatcher`).
    static func sharedLeftoverReason(_ note: String) -> String {
        "Zuordnung nach aktuellem Stand unsicher (\(note)) – nicht angefasst."
    }

    /// Am Ort von `app` liegt jetzt `other` mit anderer Bundle-ID.
    static func replacedReason(_ app: InstalledApp, by other: InstalledApp) -> String {
        "Am Ort von „\(app.name)“ liegt jetzt eine andere App (\(other.bundleID ?? other.name)) – nicht angefasst."
    }

    /// Die App am Ort trägt dieselbe Bundle-ID, ist aber von einem anderen Team signiert.
    static func resignedReason(_ app: InstalledApp, team: String) -> String {
        "„\(app.name)“ ist am Ort jetzt von einem anderen Team signiert (\(team)) – nicht angefasst."
    }

    private struct Current {
        let installations: InstallationIndex
        let matcher: LeftoverMatcher
        /// Weitere Installationen derselben Bundle-ID, und davon die bei der Auswahl unbekannten.
        let others: [InstalledApp]
        let unknownOthers: [InstalledApp]
    }

    private enum State {
        /// Jeder Eintrag bleibt mit diesem Grund liegen.
        case blocked(String)
        case current(Current)
    }

    private let app: InstalledApp
    private let plan: RemovalPlan
    private let layout: LibraryLayout
    private let state: State

    /// - Parameters:
    ///   - app: `plan.app` – die App, die entfernt wird.
    ///   - current: Snapshot eines frischen Scans; `nil`, wenn keiner vorliegt.
    init(app: InstalledApp, plan: RemovalPlan, current: Snapshot?, layout: LibraryLayout) {
        self.app = app
        self.plan = plan
        self.layout = layout
        guard let current else {
            state = .blocked(OrphanRecheck.unavailableReason)
            return
        }
        guard current.baselineSources.contains(.apps), !current.failedSources.contains(.apps) else {
            state = .blocked(Self.missingInventoryReason)
            return
        }
        let installations = InstallationIndex(current.installedApps)
        // Die App, wie sie jetzt am Ort liegt; fehlt sie (schon entfernt), gilt der Plan.
        let fresh = installations.installation(at: app.path) ?? app
        if InstallationIndex.key(fresh.bundleID) != InstallationIndex.key(app.bundleID) {
            state = .blocked(Self.replacedReason(app, by: fresh))
            return
        }
        if let team = fresh.signing.teamID, let known = app.signing.teamID, team != known {
            state = .blocked(Self.resignedReason(app, team: team))
            return
        }
        let verification = AppleAppVerification(catalog: SystemAppCatalog(layout: layout))
        let others = installations.otherInstallations(of: app)
        state = .current(Current(
            installations: installations,
            matcher: LeftoverMatcher(app: fresh, installedApps: current.installedApps, verification: verification),
            others: others,
            unknownOthers: others.filter { !plan.knownOtherInstallations.contains(InstallationIndex.canonical($0.path)) }
        ))
    }

    /// Grund zum Überspringen des Rests; `nil`, wenn er weiterhin (so sicher wie bei der Suche) zur App gehört.
    func reason(for candidate: LeftoverCandidate) -> String? {
        switch state {
        case .blocked(let reason):
            return reason
        case .current(let current):
            guard candidate.kind != .appBundle else { return nil }
            let directory = (candidate.path as NSString).deletingLastPathComponent
            let name = (candidate.path as NSString).lastPathComponent
            guard let location = layout.leftoverLocations.first(where: { $0.directory == directory }) else {
                return Self.unknownLocationReason
            }
            guard let match = current.matcher.match(name: name, in: location) else { return Self.otherOwnerReason(app) }
            switch (candidate.confidence, match.confidence) {
            case (_, .safe): return nil
            case (.safe, .uncertain): return match.note.map(Self.sharedLeftoverReason) ?? Self.otherOwnerReason(app)
            case (.uncertain, .uncertain): return match.note.flatMap { $0 == candidate.note ? nil : Self.sharedLeftoverReason($0) }
            }
        }
    }

    /// Grund zum Überspringen der Berechtigung; `nil`, wenn sie nach dem aktuellen Stand (allein) der App gehört.
    func reason(for grant: PermissionGrant) -> String? {
        reason(id: grant.id) { $0.assignment(of: grant, to: app) }
    }

    /// Grund zum Überspringen des Autostart-Eintrags; `nil`, wenn er nach dem aktuellen Stand (allein) der App gehört.
    func reason(for item: AutostartItem) -> String? {
        reason(id: item.id) { $0.assignment(of: item, to: app) }
    }

    private func reason(id: String, assignment: (InstallationIndex) -> LinkAssignment) -> String? {
        switch state {
        case .blocked(let reason):
            return reason
        case .current(let current):
            switch assignment(current.installations) {
            case .exclusive: return nil
            case .shared where plan.acknowledgedSharedIDs.contains(id) && current.unknownOthers.isEmpty: return nil
            case .shared where plan.acknowledgedSharedIDs.contains(id): return Self.sharedReason(with: current.unknownOthers)
            case .shared: return Self.sharedReason(with: current.others)
            case .conflict, .unrelated: return Self.otherOwnerReason(app)
            }
        }
    }
}
