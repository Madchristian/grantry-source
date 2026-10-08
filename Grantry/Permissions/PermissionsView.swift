import ManagerKit
import SwiftUI

/// Berechtigungen (Spec §6): umschaltbar nach App oder nach Berechtigung, Liste links mit Scan-Abdeckung darüber (#142),
/// Detail rechts; Suche und Filter in der Symbolleiste. Liest nur aus `AppModel.presentation`.
struct PermissionsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var selectedAppID: AppGroup.ID?
    @State private var selectedServiceID: ServiceGroup.ID?

    var body: some View {
        @Bindable var window = window
        ListDetailSplit {
            VStack(spacing: 0) {
                SectionCoverageHeader(coverage: coverage)
                Picker("Gruppierung", selection: $window.permissionsGrouping) {
                    ForEach(PermissionsGrouping.allCases, id: \.self) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                Divider()
                switch window.permissionsGrouping {
                case .byApp: appList
                case .byService: serviceList
                }
            }
        } detail: {
            ActionResultContainer(actions: appModel.actions, context: .permissions) {
                detail
            }
        }
        .inventorySearch(for: .permissions, prompt: String(localized: "Apps und Dienste durchsuchen"))
    }

    // MARK: - Listen

    private var appList: some View {
        let groups = InventoryPresenter.filter(
            appModel.presentation?.appGroups ?? [], query: window.query(for: .permissions),
            filter: window.filter(for: .permissions)
        ).filter { !$0.grants.isEmpty }
        return ScrollViewReader { proxy in
            List(groups, selection: $selectedAppID) { group in
                GroupRow(
                    title: group.app.displayName, subtitle: group.grants.map(\.serviceName).joined(separator: ", "),
                    badges: badges(for: group.grants)
                ) {
                    AppIconView(app: group.app, size: 28)
                }
                .id(group.id)
            }
            .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
                guard let recordID, let group = groups.first(where: { $0.grants.contains { $0.id == recordID } }) else { return }
                selectedAppID = group.id
                proxy.scrollTo(group.id, anchor: .center)
            }
        }
        .overlay { emptyState(isEmpty: groups.isEmpty) }
    }

    private var serviceList: some View {
        let groups = InventoryPresenter.filter(
            appModel.presentation?.serviceGroups ?? [], query: window.query(for: .permissions),
            filter: window.filter(for: .permissions)
        )
        return List(groups, selection: $selectedServiceID) { group in
            GroupRow(
                title: group.service.displayName,
                subtitle: group.grants.map(\.client.displayName).joined(separator: ", "),
                badges: badges(for: group.grants)
            ) {
                ServiceIconView(service: group.service, size: 28)
            }
        }
        .overlay { emptyState(isEmpty: groups.isEmpty) }
    }

    private var coverage: AreaCoverage? { appModel.presentation?.coverage[.permissions] }

    private func badges(for grants: [PermissionGrant]) -> [RecordBadge] {
        appModel.presentation?.badges.badges(forAll: grants.map(\.id)) ?? []
    }

    @ViewBuilder
    private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty {
            InventoryEmptyState(section: .permissions, coverage: coverage, hasSnapshot: appModel.presentation != nil)
        }
    }

    // MARK: - Detail

    /// Detail zur Auswahl – immer mit **allen** Einträgen der App bzw. des Dienstes, unabhängig vom Filter.
    @ViewBuilder
    private var detail: some View {
        switch window.permissionsGrouping {
        case .byApp:
            if let group = appModel.presentation?.appGroups.first(where: { $0.id == selectedAppID }) {
                AppDetailView(group: group, appModel: appModel)
            } else {
                noSelection("Wähle links eine App, um ihre Berechtigungen zu sehen.")
            }
        case .byService:
            if let group = appModel.presentation?.serviceGroups.first(where: { $0.id == selectedServiceID }) {
                ServiceDetailView(group: group, appModel: appModel)
            } else {
                noSelection("Wähle links eine Berechtigung, um die Apps damit zu sehen.")
            }
        }
    }

    private func noSelection(_ text: LocalizedStringKey) -> some View {
        NoSelectionView(hint: text)
    }
}

/// Zeile einer Gruppe (App bzw. Dienst): Symbol, Name, die Gegenseite ihrer Berechtigungen und zusammengefasste
/// Badges.
private struct GroupRow<Icon: View>: View {
    let title: String
    let subtitle: String
    let badges: [RecordBadge]
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            RecordBadgesRow(badges: badges)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
