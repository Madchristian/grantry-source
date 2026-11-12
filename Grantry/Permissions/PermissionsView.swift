import GrantryCharts
import ManagerKit
import SwiftUI

/// Berechtigungen im Lagebild (Spec §6; LB-2.2, #539, Entwurf LB-2.1): Zustandszeile mit Urteil, Umschalter „Nach App ·
/// Nach Berechtigung“ und Scan-Abdeckung (#142), links die Auswahlliste in den Gruppen „Mit Befund“ und „Übrige“, rechts
/// das Detail; Suche und Filter in der Symbolleiste. Liest nur aus `AppModel.presentation`; zeichnet nur bei Scan, Suche,
/// Filter, Auswahl und Aktion.
struct PermissionsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var selectedAppID: AppGroup.ID?
    @State private var selectedServiceID: ServiceGroup.ID?

    var body: some View {
        @Bindable var window = window
        let presentation = appModel.presentation
        InventoryBoard(head: PermissionsBoardMapping.head(presentation, scannedAt: appModel.monitoring.snapshot?.takenAt)) {
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                InstrumentSegments(String(localized: "Gruppierung"), selection: $window.permissionsGrouping,
                                   options: PermissionsGrouping.allCases.map { ($0, $0.title) })
                    .frame(width: InstrumentSize.columnNarrow)
                VStack(alignment: .leading, spacing: 0) {
                    if let coverage { AreaCoverageBar(coverage: coverage) }
                    FlaggedNoticeBar(breakdown: presentation?.metrics.flagged, area: .permissions,
                                     filter: window.filter(for: .permissions).findings)
                }
            }
        } list: {
            switch window.permissionsGrouping {
            case .byApp: appList(presentation)
            case .byService: serviceList(presentation)
            }
        } detail: {
            ActionResultContainer(actions: appModel.actions, context: .permissions) {
                detail(presentation)
            }
        }
        .inventorySearch(for: .permissions, prompt: String(localized: "Apps und Dienste durchsuchen"))
        .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
            guard let recordID, let group = presentation?.appGroups.first(where: {
                $0.grants.contains { $0.id == recordID }
            }) else { return }
            selectedAppID = group.id
        }
    }

    // MARK: - Listen

    @ViewBuilder
    private func appList(_ presentation: PresentationSnapshot?) -> some View {
        let groups = InventoryPresenter.filter(
            presentation?.appGroups ?? [], query: window.query(for: .permissions), filter: window.filter(for: .permissions)
        ).filter { !$0.grants.isEmpty }
        if let presentation, !groups.isEmpty {
            let apps = Dictionary(groups.map { ($0.id, $0.app) }, uniquingKeysWith: { first, _ in first })
            InstrumentList(String(localized: "Apps"), count: "\(groups.count)",
                           sections: PermissionsBoardMapping.sections(groups, isFlagged: \.isFlagged) {
                               PermissionsBoardMapping.appItem($0, presentation: presentation)
                           },
                           selection: $selectedAppID) { item in
                if let app = apps[item.id] { AppIconView(app: app, size: InstrumentSize.rowIconTall) }
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func serviceList(_ presentation: PresentationSnapshot?) -> some View {
        let groups = InventoryPresenter.filter(
            presentation?.serviceGroups ?? [], query: window.query(for: .permissions),
            filter: window.filter(for: .permissions)
        )
        if let presentation, !groups.isEmpty {
            let services = Dictionary(groups.map { ($0.id, $0.service) }, uniquingKeysWith: { first, _ in first })
            InstrumentList(String(localized: "Berechtigungen"), count: "\(groups.count)",
                           sections: PermissionsBoardMapping.sections(groups, isFlagged: \.isFlagged) {
                               PermissionsBoardMapping.serviceItem($0, presentation: presentation)
                           },
                           selection: $selectedServiceID) { item in
                if let service = services[item.id] {
                    ServiceIconView(service: service, size: InstrumentSize.rowIconTall)
                }
            }
        } else {
            emptyState
        }
    }

    private var coverage: AreaCoverage? { appModel.presentation?.coverage[.permissions] }

    /// Leerzustand im Panel (Spec §11.1 e): noch kein Scan, keine Treffer, keine Einträge – ohne Entwarnung bei Lücken.
    private var emptyState: some View {
        InventoryEmptyState(section: .permissions, coverage: coverage, hasSnapshot: appModel.presentation != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .instrumentPanel()
    }

    // MARK: - Detail

    /// Detail zur Auswahl – immer mit **allen** Einträgen der App bzw. des Dienstes, unabhängig vom Filter.
    @ViewBuilder
    private func detail(_ presentation: PresentationSnapshot?) -> some View {
        switch window.permissionsGrouping {
        case .byApp:
            if let presentation, let group = presentation.appGroups.first(where: { $0.id == selectedAppID }) {
                AppDetailView(group: group, appModel: appModel, presentation: presentation)
            } else {
                noSelection(String(localized: "Wähle links eine App, um ihre Berechtigungen zu sehen."))
            }
        case .byService:
            if let presentation, let group = presentation.serviceGroups.first(where: { $0.id == selectedServiceID }) {
                ServiceDetailView(group: group, appModel: appModel, presentation: presentation)
            } else {
                noSelection(String(localized: "Wähle links eine Berechtigung, um die Apps damit zu sehen."))
            }
        }
    }

    private func noSelection(_ message: String) -> some View {
        InstrumentEmptyState(symbol: "hand.raised", title: String(localized: "Nichts gewählt"), message: message)
            .instrumentPanel()
    }
}
