import GrantryCharts
import ManagerKit
import SwiftUI

/// Bereich „Sicherheit“ im Lagebild (Spec 2026-11-08 §5.5, #407, #408): oben die Lagezeile mit dem Urteil aus den
/// Prüfungen, darunter links Steckbrief und Sprungzeilen (`MacProfileSection`), rechts das Panel „Schutz“ mit einer
/// Zeile je Prüfung. Darüber die Scan-Abdeckung (#142) und die Meldung zur letzten Aktion. Liest nur aus
/// `AppModel.presentation` und beim Öffnen einmal den Steckbrief; nichts misst oder zeichnet im Takt.
struct SecurityView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel

    var body: some View {
        ActionResultContainer(actions: appModel.actions, context: .security) {
            VStack(spacing: 0) {
                SectionCoverageHeader(coverage: appModel.presentation?.coverage[.security])
                if let overview = appModel.presentation?.security, !overview.checks.isEmpty {
                    SecurityBoard(overview: overview, actions: appModel.actions, helperState: prerequisites.helperState)
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
        .instrumentBackground()
    }
}

/// Lagezeile, Steckbrief und Panel „Schutz“. Ein Klick klappt eine Prüfung auf: Erklärung, Details und ihre Angebote
/// (`SecurityCheckOffers`). Beim Öffnen ist die wichtigste offene Prüfung aufgeklappt (`leadingCheckID`); ein Sprung aus
/// einer Benachrichtigung oder dem Verlauf klappt deren Prüfung auf und scrollt zu ihr.
private struct SecurityBoard: View {
    let overview: SecurityOverview
    let actions: ActionRunner
    let helperState: HelperState?
    @Environment(MainWindowModel.self) private var window
    @State private var selection: String?

    var body: some View {
        let verdict = overview.verdict(helperState: helperState)
        ScrollViewReader { proxy in
            ChartScrollView(showsIndicators: true) {
                VStack(spacing: InstrumentSpacing.panel) {
                    VerdictBar(verdict: verdict.title, reason: verdict.reason, finding: verdict.hasFinding,
                               items: verdict.statusItems, facts: verdict.facts)
                    InstrumentSideColumnLayout.profileAndChecks {
                        MacProfileSection()
                        CheckPanel(String(localized: "Schutz"), detail: overview.panelDetail, value: overview.panelValue,
                                   finding: overview.hintCount > 0, note: SecurityOverview.helperNote(for: helperState),
                                   items: overview.checks.map(\.checkItem), selection: $selection) { item in
                            if let check = overview.checks.first(where: { $0.id == item.id }) {
                                SecurityCheckOffers(check: check, actions: actions, helperState: helperState)
                            }
                        }
                    }
                }
                .padding(InstrumentSpacing.page)
            }
            .onChange(of: window.focusedRecordID, initial: true) { _, id in
                if let id {
                    selection = id
                    proxy.scrollTo(id, anchor: .top)
                } else if selection == nil {
                    selection = overview.leadingCheckID
                }
            }
        }
    }
}
