import GrantryCharts
import ManagerKit
import SwiftUI

/// Autostart im Lagebild (Spec §6; LB-2.3, #540, Entwurf LB-2.1): Zustandszeile mit Urteil, Scan-Abdeckung (#142) und
/// Hinweis auf andere Bereiche, links die Einträge je Art als Auswahlliste, rechts das Detail mit Aktionen; Suche und
/// Filter in der Symbolleiste. Liest nur aus `AppModel.presentation`; zeichnet nur bei Scan, Suche, Filter, Auswahl und
/// Aktion.
struct AutostartView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var selection: AutostartItem.ID?

    var body: some View {
        let presentation = appModel.presentation
        InventoryBoard(head: AutostartBoardMapping.head(presentation, scannedAt: appModel.monitoring.snapshot?.takenAt)) {
            VStack(alignment: .leading, spacing: 0) {
                if let coverage { AreaCoverageBar(coverage: coverage) }
                FlaggedNoticeBar(breakdown: presentation?.metrics.flagged, area: .autostart,
                                 filter: window.filter(for: .autostart).findings)
            }
        } list: {
            list(presentation)
        } detail: {
            ActionResultContainer(actions: appModel.actions, context: .autostart) {
                detail(presentation)
            }
        }
        .inventorySearch(for: .autostart, prompt: String(localized: "Autostart-Einträge durchsuchen"))
        // Sprung aus anderen Bereichen (App-Detail, Verlauf, Übersicht) wählt den Eintrag; die Liste rollt ihn ins Bild.
        .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
            guard let recordID else { return }
            selection = recordID
        }
    }

    // MARK: - Liste

    @ViewBuilder
    private func list(_ presentation: PresentationSnapshot?) -> some View {
        let sections = InventoryPresenter.filter(
            presentation?.autostartSections ?? [], query: window.query(for: .autostart),
            filter: window.filter(for: .autostart)
        )
        if let presentation, !sections.isEmpty {
            let items = Dictionary(sections.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            InstrumentList(String(localized: "Einträge"), count: "\(items.count)",
                           sections: AutostartBoardMapping.sections(sections, presentation: presentation),
                           selection: $selection) { entry in
                if let item = items[entry.id] { AutostartItemIcon(item: item) }
            }
        } else {
            InventoryEmptyState(section: .autostart, coverage: coverage, hasSnapshot: presentation != nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .instrumentPanel()
        }
    }

    private var coverage: AreaCoverage? { appModel.presentation?.coverage[.autostart] }

    // MARK: - Detail

    /// Detail zur Auswahl – unabhängig vom Filter, solange der Eintrag im aktuellen Snapshot existiert.
    @ViewBuilder
    private func detail(_ presentation: PresentationSnapshot?) -> some View {
        if let presentation,
           let item = presentation.autostartSections.lazy.flatMap(\.items).first(where: { $0.id == selection }) {
            AutostartDetailView(item: item, presentation: presentation, actions: appModel.actions)
        } else {
            InstrumentEmptyState(
                symbol: "hand.raised", title: String(localized: "Nichts gewählt"),
                message: String(localized: "Wähle links einen Autostart-Eintrag, um Details und Aktionen zu sehen.")
            )
            .instrumentPanel()
        }
    }
}
