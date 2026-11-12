import GrantryCharts
import ManagerKit
import SwiftUI

/// Bereich „Beobachtungen“ (#127) im Lagebild (LB-3.4, #546; Entwurf LB-3.1, #543): Zustandszeile ohne Urteil, links
/// laufende und gespeicherte Beobachtungen als Auswahlliste, rechts Bilanz und Aufräumen. Zeichnet nur bei neuen Daten
/// (Ablage, Scan, Auswahl); kein Takt.
struct ObservationsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window

    private var observations: ObservationModel { appModel.observations }

    var body: some View {
        @Bindable var window = window
        let head = ObservationsBoardMapping.head(summaries: observations.summaries,
                                                 liveAddedCount: observations.liveAddedCount)
        Group {
            if observations.summaries.isEmpty {
                ObservationsEmptyBoard(head: head, message: String(localized: "Starte eine Beobachtung, bevor du ein Tool installierst – danach zeigt Grantry, was es eingerichtet hat.")) {
                    VStack(spacing: InstrumentSpacing.group) {
                        if let error = observations.errorMessage { InstrumentNote(error, kind: .critical) }
                        Button("Installation beobachten …") { window.isObservationStartPresented = true }
                            .disabled(!observations.isAvailable)
                    }
                }
            } else {
                InventoryBoard(head: head) {
                    EmptyView()
                } list: {
                    list(selection: $window.selectedObservationID)
                } detail: {
                    detail
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Installation beobachten …", systemImage: "binoculars") { window.isObservationStartPresented = true }
                    .disabled(observations.active != nil || !observations.isAvailable)
                    .help("Installation beobachten …")
            }
        }
        .task { await observations.load() }
    }

    private func list(selection: Binding<UUID?>) -> some View {
        let sections = ObservationsBoardMapping.sections(observations.summaries,
                                                         liveAddedCount: observations.liveAddedCount)
        return VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            if let error = observations.errorMessage { InstrumentNote(error, kind: .critical) }
            InstrumentList(String(localized: "Beobachtungen"), count: "\(observations.summaries.count)",
                           sections: sections, selection: selection)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = window.selectedObservationID {
            ObservationDetailView(appModel: appModel, observationID: id)
                .id(id)
        } else {
            InstrumentEmptyState(symbol: ObservationsBoardMapping.symbol, title: String(localized: "Nichts gewählt"),
                                 message: String(localized: "Wähle links eine Beobachtung, um ihre Bilanz zu sehen."))
                .instrumentPanel()
        }
    }
}
