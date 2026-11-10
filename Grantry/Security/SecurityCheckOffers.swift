import GrantryCharts
import ManagerKit
import SwiftUI

/// Angebote einer aufgeklappten Prüfung (Aktionen bzw. Links) aus `SecurityCheckPresentation.offers`, unverändert:
/// Helper-Aktionen nur bei bereitem Helper (`SecurityOverview.isAvailable`) und solange keine andere Aktion läuft; sie
/// schalten nur ein und brauchen daher keine Bestätigung.
struct SecurityCheckOffers: View {
    let check: SecurityCheckPresentation
    let actions: ActionRunner
    let helperState: HelperState?
    @Environment(\.openURL) private var openURL
    @Environment(\.self) private var environment

    var body: some View {
        if !check.offers.isEmpty {
            HStack(spacing: InstrumentSpacing.group) {
                ForEach(check.offers, id: \.self) { offer in
                    switch offer {
                    case .action(let action, let title):
                        Button(title) { Task { await actions.perform(action) } }
                            .disabled(!actions.canStart || !SecurityOverview.isAvailable(action, helperState: helperState))
                    case .link(let title, let url):
                        // In SwiftUI gezeichnet statt `.link`, in der Textfarbe von `info` (Standard §2.5).
                        Button(title) { openURL(url) }
                            .buttonStyle(.plain)
                            .foregroundStyle(environment.statusTextColor(.info))
                            .accessibilityAddTraits(.isLink)
                    }
                }
                if actions.runningRecordID == check.id {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Aktion läuft")
                }
            }
            .padding(.top, InstrumentSpacing.stack)
        }
    }
}

extension SecurityCheckPresentation {
    /// Zeile im Panel „Schutz“: Symbol der Prüfung, Klartext als Grund, Ampel als Zustandschip (Standard §2.5).
    var checkItem: CheckItem {
        CheckItem(id: id, symbol: systemImage, title: title, reason: summary,
                  status: StatusItem(statusText, tone: tone.statusTone), explanation: explanation, details: details)
    }
}
