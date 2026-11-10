import ManagerKit

/// Bereiche des Hauptfensters in Sidebar-Reihenfolge (Spec §6, Layout „Dashboard zuerst“; „Task-Manager“ nach „Übersicht“,
/// Spec 2026-11-06; „Aufräumen“ unter „Apps“, Spec v3 §3; „Beobachtungen“ darunter, #127; „Agenten“ nach „Autostart“,
/// #129; „Erweiterungen“ nach „Autostart“, Spec 2026-11-08 § 5.2).
enum MainSection: String, Hashable, CaseIterable, Identifiable {
    case overview, taskManager, apps, cleanup, observations, permissions, autostart, extensions, agents, network, security,
         history

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: String(localized: "Übersicht")
        case .taskManager: String(localized: "Task-Manager")
        case .apps: String(localized: "Apps")
        case .cleanup: String(localized: "Aufräumen")
        case .observations: String(localized: "Beobachtungen")
        case .permissions: String(localized: "Berechtigungen")
        case .autostart: String(localized: "Autostart")
        case .extensions: String(localized: "Erweiterungen")
        case .network: String(localized: "Netzwerk")
        case .agents: String(localized: "Agenten")
        case .security: String(localized: "Sicherheit")
        case .history: String(localized: "Verlauf")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .taskManager: "gauge.with.dots.needle.67percent"
        case .apps: "square.stack.3d.up"
        case .cleanup: "trash.circle"
        case .observations: "binoculars"
        case .permissions: "hand.raised"
        case .autostart: "power.circle"
        case .extensions: "puzzlepiece.extension"
        case .network: "network"
        case .agents: "server.rack"
        case .security: "lock.shield"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Bereiche mit Suchfeld in der Symbolleiste; „Erweiterungen“ sucht wie Verbindungen im Inhalt.
    var isSearchable: Bool {
        filterContext != nil || self == .apps || self == .agents || self == .network
    }

    /// Beschriftungskontext der Listenfilter (`ListFilter`); `nil` für Bereiche ohne dieses Filtermenü – „Apps“ und
    /// „Netzwerk“ filtern eigens (`AppListFilter`, `NetworkListenerFilter`), „Agenten“ nur mit „Nur auffällige“
    /// (`AgentFilterMenu`).
    var filterContext: FilterContext? {
        switch self {
        case .permissions: .permissions
        case .autostart: .autostart
        case .overview, .taskManager, .apps, .cleanup, .observations, .extensions, .agents, .network, .security, .history: nil
        }
    }
}
