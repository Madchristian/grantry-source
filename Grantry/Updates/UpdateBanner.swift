import GrantryCharts
import ManagerKit
import SwiftUI

/// Hinweis oben in der Übersicht, solange eine neuere Version verfügbar ist.
struct UpdateBanner: View {
    let item: AppcastItem
    let updates: UpdateModel

    var body: some View {
        InstrumentBanner(
            UpdateTexts.availableTitle,
            message: updates.installationError ?? updates.installationStatus ?? "\(item.availabilityText) \(updates.supportsInstallation ? "" : UpdateTexts.installHint)",
            tone: .info
        ) {
            UpdateChecksumView(item: item)
            if item.hasReleaseNotes {
                Button(UpdateTexts.releaseNotes) { updates.openReleaseNotes(item) }
            }
            Button(updates.downloadButtonTitle) { updates.openDownload(item) }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Symbol des Update-Hinweises (Übersicht und Menüleiste).
    static let systemImage = "arrow.down.circle.fill"
}
