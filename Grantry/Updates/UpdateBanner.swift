import ManagerKit
import SwiftUI

/// Hinweis oben in der Übersicht, solange eine neuere Version verfügbar ist.
struct UpdateBanner: View {
    let item: AppcastItem
    let updates: UpdateModel

    var body: some View {
        DashboardBanner(
            systemImage: UpdateBanner.systemImage, tint: .accentColor, title: UpdateTexts.availableTitle,
            text: updates.installationError ?? updates.installationStatus ?? "\(item.availabilityText) \(updates.supportsInstallation ? "" : UpdateTexts.installHint)"
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
