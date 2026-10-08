import ManagerKit
import SwiftUI

/// Bereich „Beobachtungen“ (#127): links laufende und gespeicherte Beobachtungen, rechts Bilanz und Aufräumen.
struct ObservationsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window

    private var observations: ObservationModel { appModel.observations }

    var body: some View {
        @Bindable var window = window
        ListDetailSplit {
            list(selection: $window.selectedObservationID)
        } detail: {
            if let id = window.selectedObservationID {
                ObservationDetailView(appModel: appModel, observationID: id)
                    .id(id)
            } else {
                NoSelectionView(hint: "Wähle links eine Beobachtung, um ihre Bilanz zu sehen.")
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
        List(selection: selection) {
            if let error = observations.errorMessage {
                NoticeList(notices: [error])
                    .listRowSeparator(.hidden)
            }
            ForEach(observations.summaries) { summary in
                ObservationSummaryRow(summary: summary, liveAddedCount: summary.isActive ? observations.liveAddedCount : nil)
                    .tag(summary.id)
            }
        }
        .overlay {
            if observations.summaries.isEmpty {
                ContentUnavailableView {
                    Label("Keine Beobachtungen", systemImage: MainSection.observations.systemImage)
                } description: {
                    Text("Starte eine Beobachtung, bevor du ein Tool installierst – danach zeigt Grantry, was es eingerichtet hat.")
                } actions: {
                    Button("Installation beobachten …") { window.isObservationStartPresented = true }
                        .disabled(!observations.isAvailable)
                }
            }
        }
    }
}

/// Zeile einer Beobachtung: Name, Zeitraum, Zahl neuer Einträge bzw. „läuft“.
private struct ObservationSummaryRow: View {
    let summary: ObservationSummary
    let liveAddedCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: summary.name).fontWeight(.medium).lineLimit(1)
                if summary.isActive {
                    Text("läuft")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let start = summary.startedAt.formatted(date: .abbreviated, time: .shortened)
        let count = summary.isActive ? liveAddedCount : summary.addedCount
        let entries = count.map { ObservationTexts.entries($0) }
        let cleanups = summary.cleanupCount > 0 ? String(localized: "aufgeräumt") : nil
        return [start, entries, cleanups].compactMap(\.self).joined(separator: " · ")
    }
}
