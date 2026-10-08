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
    /// „Dienste | Aktivität“ im Bereich „Netzwerk“; gemerkt über Neustarts.
    var networkMode = NetworkMode.restored() {
        didSet { networkMode.save() }
    }
    /// Gruppierung der Berechtigungen.
    var permissionsGrouping: PermissionsGrouping = .byApp
    /// `id` eines `InventoryRecord`, den die Liste des Bereichs auswählen soll.
    var focusedRecordID: String?
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

    /// Wechselt in `section`, optional mit Filter „nur auffällige“ (im Bereich „Netzwerk“: „von außen erreichbar“);
    /// Suche, übrige Filter (auch die des Verlaufs) und Hervorhebung werden zurückgesetzt.
    func show(_ section: MainSection, onlyFlagged: Bool = false) {
        searchText[section] = nil
        filters[section] = ListFilter(onlyFlagged: onlyFlagged)
        focusedRecordID = nil
        if section == .history { historyFilter = HistoryFilter() }
        if section == .apps { appFilter = AppListFilter(onlyFlagged: onlyFlagged, sort: appFilter.sort) }
        if section == .network {
            networkFilter = NetworkListenerFilter()
            networkFilter.onlyExposed = onlyFlagged
            if onlyFlagged { networkMode = .services }
        }
        self.section = section
    }

    /// Zeigt den Bereich des Wunsches und hebt dort den gewünschten Eintrag hervor.
    func show(_ request: MainWindowRequest) {
        show(request.section)
        focusedRecordID = request.focusedRecordID
        if request.section == .network, request.focusedRecordID != nil { networkMode = .services }
        if let observationID = request.observationID { selectedObservationID = observationID }
        if request.opensObservationStart { isObservationStartPresented = true }
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
        guard event.kind != .removed else { return show(.history) }
        switch event.subject {
        case .grant:
            show(.permissions)
            permissionsGrouping = .byApp
        case .autostartItem:
            show(.autostart)
        case .securityCheck:
            show(.security)
        case .installedApp:
            show(.apps)
        case .networkListener:
            show(.network)
            networkMode = .services
        case .mcpServer, .agentAutoApproval:
            show(.agents)
        }
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
    var onlyFlagged = false

    /// Ob ein Filter von der Vorgabe abweicht.
    var isActive: Bool { self != ListFilter() }
}

extension InventoryPresenter {
    /// Filtert mit Suchtext und Filter eines Bereichs.
    static func filter(_ groups: [AppGroup], query: String, filter: ListFilter) -> [AppGroup] {
        Self.filter(groups, query: query, state: filter.state, scope: filter.scope, onlyFlagged: filter.onlyFlagged)
    }

    static func filter(_ groups: [ServiceGroup], query: String, filter: ListFilter) -> [ServiceGroup] {
        Self.filter(groups, query: query, state: filter.state, scope: filter.scope, onlyFlagged: filter.onlyFlagged)
    }

    static func filter(_ sections: [AutostartSection], query: String, filter: ListFilter) -> [AutostartSection] {
        Self.filter(sections, query: query, state: filter.state, scope: filter.scope, onlyFlagged: filter.onlyFlagged)
    }
}
