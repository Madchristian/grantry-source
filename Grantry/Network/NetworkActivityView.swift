import GrantryCharts
import ManagerKit
import SwiftUI

/// Ansicht „Aktivität“ im Bereich Netzwerk, Gestaltung „Lagebild“ (#366): welche Prozesse gerade senden und empfangen,
/// mit Rate und Zielen (live über nettop). Oben die Zustandszeile, darunter der Datenverkehr des Macs mit Kennzahlen,
/// Suche, Umschalter und die Tabelle (`NetworkActivityBoard`). Misst nur, solange sie angezeigt wird und ihr Fenster
/// sichtbar ist (`measuresWhileVisible`); Fehler und Hinweise stehen darüber in derselben Leiste wie die Scan-Abdeckung
/// (`NoticeBarLayout`).
struct NetworkActivityView: View {
    @Bindable var model: NetworkActivityModel
    /// Lauscher des aktuellen Snapshots („Zum Netzwerkdienst“).
    let listeners: [NetworkListener]
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        let overview = NetworkActivityOverview(report: model.frame.report)
        let verdict = overview.verdict
        VStack(spacing: 0) {
            if let notice = model.notice {
                NetworkActivityNoticeBar(notice: notice, retry: model.retry)
                Divider()
            }
            StatusLine(verdict: verdict.title, finding: verdict.hasFinding, items: verdict.statusItems,
                       facts: verdict.facts)
                .padding([.horizontal, .top], InstrumentSpacing.page)
            NetworkActivityBoard(
                rows: model.rows, overview: overview, history: model.frame.report.history,
                measures: model.status.failure == nil, filter: $model.filter, query: $model.query,
                sortOrder: $model.sortOrder, listeners: listeners, showListener: { window.show($0) }
            ) {
                emptyState
            }
        }
        .instrumentBackground()
        .toolbar {
            ToolbarItem { NetworkActivityFilterMenu(filter: $model.filter) }
        }
        .measuresWhileVisible(start: { model.start(for: .activityView) }, stop: { model.stop(for: .activityView) })
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.status.failure != nil {
            ContentUnavailableView("Keine Messwerte", systemImage: "network.slash",
                                   description: Text("Ohne nettop zeigt Grantry keine Zahlen."))
        } else if model.frame.report.history.isEmpty {
            ProgressView("Messe Netzwerkaktivität …")
        } else if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else if model.filter.isActive {
            NoFilterMatchesView(description: "Kein Prozess passt zu den gewählten Filtern.") {
                model.filter = NetworkActivityFilter()
            }
        } else {
            ContentUnavailableView("Gerade keine Netzwerkaktivität", systemImage: "network",
                                   description: Text("Kein Prozess sendet oder empfängt gerade Daten (Apple-Systemdienste ausgeblendet)."))
        }
    }
}

/// Fehler- oder Teilhinweis der Aktivität, gestaltet wie die Abdeckungsleiste; „Erneut versuchen“, wenn es helfen kann.
struct NetworkActivityNoticeBar: View {
    let notice: NetworkActivityNotice
    let retry: () -> Void

    var body: some View {
        NoticeBarLayout(systemImage: notice.systemImage, tone: notice.tone, headline: notice.headline,
                        accessibilityLabel: notice.headline, isEmphasized: true, reasons: notice.reasons) {
            if notice.offersRetry {
                Button("Erneut versuchen", action: retry)
                    .buttonStyle(.link)
            }
        }
    }
}

// MARK: - Vorschauen

#if DEBUG
private struct NetworkActivityPreview: View {
    let model: NetworkActivityModel

    var body: some View {
        NavigationStack {
            NetworkActivityView(model: model, listeners: [.preview])
        }
        .environment(MainWindowModel())
        .frame(width: 1240, height: 780)
    }
}

#Preview("Aktivität hell") {
    NetworkActivityPreview(model: .preview(frame: NetworkActivityPreviewData.frame, status: .running,
                                           hostNames: NetworkActivityPreviewData.hostNames))
        .preferredColorScheme(.light)
}

#Preview("Aktivität dunkel") {
    NetworkActivityPreview(model: .preview(frame: NetworkActivityPreviewData.frame, status: .running,
                                           hostNames: NetworkActivityPreviewData.hostNames))
        .preferredColorScheme(.dark)
}

#Preview("Leer") {
    NetworkActivityPreview(model: .preview(frame: NetworkActivityPreviewData.quietFrame, status: .running))
}

#Preview("Fehler") {
    NetworkActivityPreview(model: .preview(frame: .empty, status: .failed(.unavailable(
        reason: "Die Datei „nettop“ konnte nicht geöffnet werden, da sie nicht existiert."
    ))))
}

#Preview("Formatfehler") {
    NetworkActivityPreview(model: .preview(frame: .empty, status: .failed(.unrecognizedFormat)))
}
#endif
