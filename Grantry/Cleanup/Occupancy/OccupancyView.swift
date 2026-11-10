import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

/// Segment „Belegung“ (TM-15.4, #403; Spec 2026-11-08 § 5.4): frei erkunden, wo der Platz liegt, und sicher zum
/// Aufräumen springen – im Lagebild (`OccupancyBoard`). Kein Löschen (Entscheidung O4): nur „Im Finder zeigen“ und der
/// Sprung zur Kategorie in Speicher. Gemessen wird nur, solange das Segment zu sehen ist.
struct OccupancyView: View {
    let model: OccupancyModel
    /// Befunde der Lagezeile (`TaskManagerModel.findings`); laufende Datenträger-Befunde setzen den Befund-Punkt.
    let findings: [SystemFinding]
    let isFullDiskAccessMissing: Bool
    let openFullDiskAccess: () -> Void
    /// Springt in Speicher zur Kategorie mit dieser `id`.
    let openCategory: (String) -> Void

    var body: some View {
        let presentation = model.presentation(findings: findings)
        OccupancyBoard(
            content: presentation.boardContent,
            scope: Binding(get: { model.state.scope.boardScope }, set: { model.setScope(OccupancyScope($0)) }),
            actions: OccupancyBoardActions(
                scan: model.scan, cancel: model.cancel, select: model.select, ascend: model.ascend(to:),
                showInFinder: {
                    guard let path = presentation.detail?.path else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                },
                openCleanup: {
                    guard let category = presentation.detail?.categoryID else { return }
                    openCategory(category)
                },
                openFullDiskAccess: openFullDiskAccess))
        .onAppear(perform: model.appear)
        .onDisappear(perform: model.disappear)
        .onChange(of: isFullDiskAccessMissing, initial: true) { _, isMissing in
            model.setFullDiskAccessMissing(isMissing)
        }
    }
}
