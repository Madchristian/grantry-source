import GrantryCharts
import ManagerKit
import SwiftUI

/// Zustandszeile über den Tabs mit dem Urteil über den Zustand jetzt; die Übersicht zeigt es groß als Lagezeile, das
/// Wachbuch urteilt über seinen Zeitraum. Als eigene Ansicht (#489), damit nur sie und der Tab je Messtakt neu
/// ausgewertet werden, nicht der Rahmen um beide.
struct TaskManagerStatusLine: View {
    let model: TaskManagerModel

    var body: some View {
        let verdict = SystemVerdictPresentation.verdict(snapshot: model.frame.snapshot, findings: model.findings,
                                                        interval: model.interval.title, uptime: SystemUptime.sinceBoot())
        StatusLine(verdict: verdict.title, finding: verdict.hasFinding, items: verdict.statusItems,
                   facts: verdict.facts)
    }
}
