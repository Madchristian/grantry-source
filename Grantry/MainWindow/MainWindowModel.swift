import Foundation
import ManagerKit
import Observation

/// Navigationszustand des Hauptfensters: gewählter Bereich, Suche und Filter je Liste sowie der Eintrag, den eine
/// Liste hervorheben soll (z. B. nach einem Klick in der Übersicht).
@MainActor
@Observable
final class MainWindowModel {
    var section: MainSection = {
        #if DEBUG
        DevelopmentLaunchOptions.initialSection ?? .overview
        #else
        .overview
        #endif
    }()
    /// Suchtext je durchsuchbarem Bereich; bleibt beim Wechsel erhalten.
    var searchText: [MainSection: String] = [:]
    /// Filter je Bereich; fehlt einer, gilt `ListFilter()`.
    var filters: [MainSection: ListFilter] = [:]
    /// Filter des Verlaufs.
    var historyFilter = HistoryFilter()
    /// Filter und Sortierung der App-Liste.
    var appFilter = AppListFilter()
    /// Filter der Liste „Netzwerk“.
    var networkFilter = NetworkListenerFilter()
    /// „Verbindungen | Dienste | Aktivität“ im Bereich „Netzwerk“; gemerkt über Neustarts.
    var networkMode = NetworkMode.restored() {
        didSet { networkMode.save() }
    }
    /// Tab im Bereich „Task-Manager“; gemerkt über Neustarts.
    var taskManagerTab = TaskManagerTab.restored() {
        didSet { taskManagerTab.save() }
    }
    /// Kachel, die „Leistung“ wählen soll (Sprung aus der Menüleiste, TM17); „Leistung“ setzt sie danach zurück.
    var performanceFocus: PerformanceMetric?
    /// Gruppierung der Berechtigungen.
    var permissionsGrouping: PermissionsGrouping = .byApp
    /// „App-Reste | Speicher | Prozesse“ im Bereich „Aufräumen“; bleibt beim Wechsel des Bereichs erhalten.
    var cleanupSegment = CleanupSegment.leftovers
    /// Kategorie, die „Speicher“ zeigen soll (Sprung aus „Belegung“, #403); Speicher setzt sie danach zurück.
    var storageFocusCategoryID: String?
    /// `id` eines `InventoryRecord`, den die Liste des Bereichs auswählen soll.
    var focusedRecordID: String?
    /// Prozess, den der Tab „Details“ wählen soll (Sprung aus dem Wachbuch, TM-12.6); Details setzt ihn danach zurück.
    var focusedProcess: ProcessKey?
    /// Zeitpunkt, an den das Wachbuch die Zeitmarke setzen soll (Mitteilung, TM-12.8a); das Wachbuch setzt ihn danach
    /// zurück.
    var watchbookMarker: Date?
    /// Offenes Entfernen-Blatt (`RemovalSheet`).
    var removalRequest: RemovalRequest?
    /// Das Onboarding-Blatt ist offen (von `RootView` nachgeführt).
    var isOnboardingPresented = false
    /// Blatt „Installation beobachten“ (#127).
    var isObservationStartPresented = false
    /// Gewählte Beobachtung im Bereich „Beobachtungen“.
    var selectedObservationID: UUID?

    /// Ein Blatt liegt über dem Fenster – Menübefehle des Fensters (⌘⌫) ruhen dann.
    var presentsSheet: Bool { removalRequest != nil || isOnboardingPresented || isObservationStartPresented }

    /// Öffnet das Entfernen-Blatt für `app`; mit `isPreview` nur zum Ansehen (nicht bestätigbar).
    func requestRemoval(of app: InstalledApp, mode: RemovalRequest.Mode = .uninstall, isPreview: Bool = false) {
        removalRequest = RemovalRequest(app: app, mode: mode, isPreview: isPreview)
    }

    /// Wechselt in `section`, optional mit Befund-Filter (im Bereich „Netzwerk“: „von außen erreichbar“,
    /// `NetworkListenerFilter.flagged`); Suche, übrige Filter (auch die des Verlaufs) und Hervorhebung werden zurückgesetzt.
    func show(_ section: MainSection, findings: FindingFilter = .all) {
        searchText[section] = nil
        filters[section] = ListFilter(findings: findings)
        focusedRecordID = nil
        if section == .history { historyFilter = HistoryFilter() }
        if section == .apps { appFilter = AppListFilter(findings: findings, sort: appFilter.sort) }
        if section == .network {
            networkFilter = findings.isActive ? .flagged : NetworkListenerFilter()
            if findings.isActive { networkMode = .services }
        }
        self.section = section
    }

    /// Befund-Filter der Liste „Netzwerk“ für den Hinweis auf weitere Bereiche (`FlaggedNotice`): der, mit dem sie
    /// geöffnet wurde, solange „Von außen erreichbar“ gilt; von Hand gesetzt „nur auffällige“.
    var networkFindings: FindingFilter {
        guard networkFilter.onlyExposed else { return .all }
        let findings = filter(for: .network).findings
        return findings.isActive ? findings : .flagged
    }

    /// Zeigt den Bereich des Wunsches und hebt dort den gewünschten Eintrag hervor.
    func show(_ request: MainWindowRequest) {
        show(request.section)
        focusedRecordID = request.focusedRecordID
        if request.section == .network, request.focusedRecordID != nil { networkMode = .services }
        if let observationID = request.observationID { selectedObservationID = observationID }
        if let cleanupSegment = request.cleanupSegment { self.cleanupSegment = cleanupSegment }
        if let taskManagerTab = request.taskManagerTab { self.taskManagerTab = taskManagerTab }
        if let performanceMetric = request.performanceMetric { performanceFocus = performanceMetric }
        watchbookMarker = request.watchbookMarker
        if request.opensObservationStart { isObservationStartPresented = true }
    }

    /// Sprung aus dem Wachbuch (TM-12.6) in den zuständigen Bereich: Prozess in „Details“, Verlaufseintrag, Autostart,
    /// Erweiterungen, Netzwerk › Verbindungen.
    func show(_ target: WatchbookJumpTarget) {
        switch target {
        case .process(let key):
            focusedProcess = key
            taskManagerTab = .details
        case .historyEntry(let id):
            show(.history)
            focusedRecordID = id.uuidString
        case .autostart:
            show(.autostart)
        case .extensions:
            show(.extensions)
        case .networkConnections:
            show(.network)
            networkMode = .connections
        }
    }

    /// Zeigt die Beobachtung `id` im Bereich „Beobachtungen“.
    func showObservation(_ id: UUID) {
        show(.observations)
        selectedObservationID = id
    }

    /// Zeigt den Eintrag, den `event` betrifft: vorhandene in ihrer Liste, entfernte im Verlauf.
    func show(_ event: HistoryEvent) {
        show(event.event)
    }

    /// Zeigt den Eintrag, den `event` betrifft: vorhandene in ihrer Liste, entfernte im Verlauf.
    func show(_ event: ChangeEvent) {
        let section = MainSection(showing: event)
        show(section)
        guard section != .history else { return }
        if section == .permissions { permissionsGrouping = .byApp }
        if section == .network { networkMode = .services }
        focusedRecordID = event.subject.recordID
    }

    /// Zeigt eine Berechtigung in der Liste „Nach App“.
    func show(_ grant: PermissionGrant) {
        show(.permissions)
        permissionsGrouping = .byApp
        focusedRecordID = grant.id
    }

    /// Zeigt einen vorhandenen Autostart-Eintrag in seiner Liste.
    func show(_ item: AutostartItem) {
        show(.autostart)
        focusedRecordID = item.id
    }

    /// Zeigt eine App in der Liste „Apps“.
    func show(_ app: InstalledApp) {
        show(.apps)
        focusedRecordID = app.id
    }

    /// Zeigt eine Erweiterung im Bereich „Erweiterungen“ mit ihrem Detail (Verweis aus Apps oder Aufräumen).
    func show(_ reference: ExtensionReference) {
        show(.extensions)
        focusedRecordID = reference.id
    }

    /// Zeigt einen Lauscher in der Liste „Netzwerk“ (Ansicht „Dienste“).
    func show(_ listener: NetworkListener) {
        show(.network)
        networkMode = .services
        focusedRecordID = listener.id
    }

    /// Suchtext des Bereichs (leer, wenn keiner gesetzt ist).
    func query(for section: MainSection) -> String { searchText[section] ?? "" }

    func filter(for section: MainSection) -> ListFilter { filters[section] ?? ListFilter() }
}

/// Berechtigungen nach App oder nach Dienst (Spec §6).
enum PermissionsGrouping: Hashable, CaseIterable {
    case byApp, byService

    var title: String {
        switch self {
        case .byApp: String(localized: "Nach App")
        case .byService: String(localized: "Nach Berechtigung")
        }
    }
}

/// Filter einer Liste (Spec §6: erlaubt/verweigert, Benutzer/System, nur auffällige).
struct ListFilter: Hashable {
    var state: GrantStateFilter = .all
    var scope: ScopeFilter = .all
    var findings: FindingFilter = .all

    /// Ob ein Filter von der Vorgabe abweicht.
    var isActive: Bool { self != ListFilter() }
    /// Nur der Befund-Filter ist gesetzt (etwa über die Kachel „Auffällig“) – leere Liste heißt dann „nichts Auffälliges“.
    var isOnlyFindings: Bool { findings.isActive && self == ListFilter(findings: findings) }
}

extension InventoryPresenter {
    /// Filtert mit Suchtext und Filter eines Bereichs.
    static func filter(_ groups: [AppGroup], query: String, filter: ListFilter) -> [AppGroup] {
        Self.filter(groups, query: query, state: filter.state, scope: filter.scope, findings: filter.findings)
    }

    static func filter(_ groups: [ServiceGroup], query: String, filter: ListFilter) -> [ServiceGroup] {
        Self.filter(groups, query: query, state: filter.state, scope: filter.scope, findings: filter.findings)
    }

    static func filter(_ sections: [AutostartSection], query: String, filter: ListFilter) -> [AutostartSection] {
        Self.filter(sections, query: query, state: filter.state, scope: filter.scope, findings: filter.findings)
    }
}

extension MainSection {
    /// Bereich, in dem `event` seinen Eintrag zeigt: vorhandene in ihrer Liste, entfernte im Verlauf (`show(_:)`, Ziel der
    /// Sprungzeilen in „Letzte Änderungen“).
    init(showing event: ChangeEvent) {
        guard event.kind != .removed else {
            self = .history
            return
        }
        self = switch event.subject {
        case .grant: .permissions
        case .autostartItem: .autostart
        case .securityCheck: .security
        case .installedApp: .apps
        case .networkListener: .network
        case .mcpServer, .agentAutoApproval: .agents
        case .taskAction: .taskManager
        case .extensionRecord: .extensions
        }
    }
}
