import ManagerKit
import SwiftUI

/// Tab „App-Verlauf“ mit dem `AppUsageModel` der App; „Verlauf löschen …“ erst nach Bestätigung.
struct AppHistoryTab: View {
    let appModel: AppModel
    @State private var range = AppUsageRange.today
    @State private var metric = AppUsageMetric.cpu
    @State private var isConfirmingClear = false

    var body: some View {
        let usage = appModel.appUsage
        AppHistoryView(summary: AppUsagePresentation.summary(of: usage.history, range: range, metric: metric,
                                                             now: .now),
                       range: $range, metric: $metric, error: usage.lastError, canClear: !usage.history.isEmpty,
                       onClear: { isConfirmingClear = true })
            .confirmationDialog("App-Verlauf löschen?", isPresented: $isConfirmingClear) {
                Button("Verlauf löschen", role: .destructive) { usage.clear() }
            } message: {
                Text("Alle gespeicherten Stunden der letzten 30 Tage werden entfernt. Das lässt sich nicht rückgängig machen.")
            }
    }
}
