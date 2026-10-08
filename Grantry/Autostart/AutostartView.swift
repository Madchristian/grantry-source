import ManagerKit
import SwiftUI

/// Autostart (Spec §6): Einträge je Art links mit Scan-Abdeckung darüber (#142), Detail mit Aktionen rechts; Suche und
/// Filter in der Symbolleiste.
/// Liest nur aus `AppModel.presentation`.
struct AutostartView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var selection: AutostartItem.ID?

    var body: some View {
        ListDetailSplit {
            VStack(spacing: 0) {
                SectionCoverageHeader(coverage: appModel.presentation?.coverage[.autostart])
                list
            }
        } detail: {
            ActionResultContainer(actions: appModel.actions, context: .autostart) {
                detail
            }
        }
        .inventorySearch(for: .autostart, prompt: String(localized: "Autostart-Einträge durchsuchen"))
    }

    // MARK: - Liste

    private var list: some View {
        let presentation = appModel.presentation
        let badges = presentation?.badges
        let sections = InventoryPresenter.filter(
            appModel.presentation?.autostartSections ?? [], query: window.query(for: .autostart),
            filter: window.filter(for: .autostart)
        )
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            AutostartItemRow(
                                item: item, badges: badges?.badges(for: item.id) ?? [],
                                sharesService: presentation?.autostartItems(sharingServiceWith: item).isEmpty == false
                            )
                            .id(item.id)
                        }
                    }
                }
            }
            .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
                guard let recordID else { return }
                selection = recordID
                proxy.scrollTo(recordID, anchor: .center)
            }
        }
        .overlay {
            if sections.isEmpty {
                InventoryEmptyState(section: .autostart, coverage: presentation?.coverage[.autostart],
                                    hasSnapshot: presentation != nil)
            }
        }
    }

    // MARK: - Detail

    /// Detail zur Auswahl – unabhängig vom Filter, solange der Eintrag im aktuellen Snapshot existiert.
    @ViewBuilder
    private var detail: some View {
        if let presentation = appModel.presentation,
           let item = presentation.autostartSections.lazy.flatMap(\.items).first(where: { $0.id == selection }) {
            AutostartDetailView(item: item, presentation: presentation, actions: appModel.actions)
        } else {
            NoSelectionView(hint: "Wähle links einen Autostart-Eintrag, um Details und Aktionen zu sehen.")
        }
    }
}
