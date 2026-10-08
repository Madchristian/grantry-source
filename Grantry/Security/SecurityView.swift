import ManagerKit
import SwiftUI

/// Bereich „Sicherheit“ (Spec v2 §3): alle Prüfungen mit Ampel, Klartext, Aktion bzw. Link. Helper-Aktionen nur bei
/// bereitem Helper; sonst ein Hinweis. Darüber die Scan-Abdeckung (#142). Aktionen brauchen keine Bestätigung (nur absichernd). Liest nur aus
/// `AppModel.presentation`.
struct SecurityView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        ActionResultContainer(actions: appModel.actions, context: .security) {
            VStack(spacing: 0) {
                SectionCoverageHeader(coverage: appModel.presentation?.coverage[.security])
                if let overview = appModel.presentation?.security, !overview.checks.isEmpty {
                    checkList(overview)
                } else {
                    ContentUnavailableView(
                        "Noch keine Sicherheitsprüfung",
                        systemImage: "lock.shield",
                        description: Text("Der Sicherheitsstatus erscheint nach dem nächsten Scan.")
                    )
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func checkList(_ overview: SecurityOverview) -> some View {
        let helperState = prerequisites.helperState
        return ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(overview.checks) { check in
                        SecurityCheckRow(
                            check: check,
                            actions: appModel.actions,
                            helperState: helperState,
                            isFocused: window.focusedRecordID == check.id
                        )
                        .id(check.id)
                    }
                } header: {
                    if let helperNote = SecurityOverview.helperNote(for: helperState) {
                        header(helperNote: helperNote)
                    }
                }
            }
            .onChange(of: window.focusedRecordID, initial: true) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    /// Hinweis, warum Helper-Aktionen gesperrt sind. „Zuletzt geprüft“ steht nur einmal, im Untertitel des Fensters.
    private func header(helperNote: String) -> some View {
        NoticeLabel(text: helperNote)
            .textCase(nil)
            .padding(.bottom, 4)
    }
}
