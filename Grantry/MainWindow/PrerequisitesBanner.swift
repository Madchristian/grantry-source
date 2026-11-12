import GrantryCharts
import ManagerKit
import SwiftUI

/// Hinweis oben in der Übersicht, solange ein erforderlicher Schritt der Einrichtung fehlt; öffnet das Onboarding.
struct PrerequisitesBanner: View {
    /// Was fehlt (`SetupChecklist.bannerText`).
    let text: String
    /// Öffnet die Einstellungen zum Festplattenvollzugriff; `nil`, wenn er nicht fehlt.
    var openFullDiskAccess: (() -> Void)?
    let showSetup: () -> Void

    var body: some View {
        InstrumentBanner(String(localized: "Voraussetzungen fehlen"), message: text, tone: PresentationTone.warning.statusTone) {
            if let openFullDiskAccess {
                Button("Festplattenvollzugriff öffnen …", action: openFullDiskAccess)
            }
            Button("Einrichtung öffnen …", action: showSetup)
        }
    }
}
