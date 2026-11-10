import Darwin
import GrantryCharts
import ManagerKit
import SwiftUI

/// Tab „Benutzer“ (Spec 2026-11-06 §6, Stufe 4): angemeldete Benutzer aus utmpx (`LoginSessionsModel`, alle 5 s,
/// solange sichtbar) mit der Summe ihrer Prozesse aus dem `TaskManagerModel`; Konten ohne Anmeldung (root,
/// Dienstkonten) als eine Zeile. CPU und Speicher fremder Prozesse kommen wie in „Prozesse“ aus `ps`, das Netz aus
/// nettop – beides nur, solange der Tab sichtbar ist. Nur Anzeige: Beenden gibt es in „Prozesse“ und „Details“.
struct UsersTab: View {
    let appModel: AppModel
    @State private var expanded: Set<String> = []
    /// Zeilen und Verläufe je Takt (#478): `ps`, nettop, utmpx und Auf- oder Zuklappen bauen sie nicht neu.
    @State private var tables = PresentationCache<Date, UserUsageTable>()

    var body: some View {
        let table = table
        UserUsageView(presentation: table.presentation, expanded: expanded, history: table.history) { row in
            if expanded.remove(row.id) == nil { expanded.insert(row.id) }
        }
        .refreshesPeriodically(every: .seconds(5)) { await appModel.loginSessions.refresh() }
        .measuresWhileVisible(start: {
            appModel.networkActivity.start(for: .taskManagerUsers)
            appModel.foreignProcessUsage.start(for: .usersTab)
        }, stop: {
            appModel.networkActivity.stop(for: .taskManagerUsers)
            appModel.foreignProcessUsage.stop(for: .usersTab)
        })
    }

    private var table: UserUsageTable {
        let model = appModel.taskManager
        return tables.value(for: model.frameDate) {
            let presentation = UserUsagePresenter.present(appModel.tableSnapshot,
                                                          sessions: appModel.loginSessions.sessions,
                                                          currentUID: getuid(),
                                                          network: appModel.networkActivity.processRates,
                                                          userName: UserNameCache.shared.name(for:))
            let history = UserUsageView.history(for: presentation, frame: model.frame, measuredAt: model.frameDate,
                                                userName: UserNameCache.shared.name(for:))
            return UserUsageTable(presentation: presentation, history: history)
        }
    }
}

/// Inhalt des Tabs „Benutzer“ eines Takts.
private struct UserUsageTable {
    let presentation: UserUsagePresentation
    let history: [UserUsageRow.ID: ChartSeries]
}
