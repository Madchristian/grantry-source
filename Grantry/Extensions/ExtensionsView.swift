import GrantryCharts
import ManagerKit
import SwiftUI

/// Bereich „Erweiterungen“ im Lagebild (TM-13.5, Spec 2026-11-08 § 5.2): oben die Zustandszeile, links die
/// Rechte-Schichten als Radar um den Kern, rechts Suche, Filter (Schicht wählen) und die Tabelle nach Schicht, darunter
/// das Detail der gewählten Erweiterung (`ExtensionBoard`). Apple-signierte Plug-ins sind ausgeblendet und gezählt. Die
/// Kachel „Auffällig“ der Übersicht öffnet den Bereich mit dem Filter „Auffällig“ (TM-13.6). Ohne Takt und ohne eigene
/// Messung: Die Ansicht zeichnet nur bei neuem Scan, Suche, Filter oder Auswahl.
struct ExtensionsView: View {
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var filter = ExtensionFilter.all
    @State private var query = ""
    @State private var selection: ExtensionRow.ID?

    var body: some View {
        let monitoring = appModel.monitoring
        let presentation = ExtensionPresentation(
            records: monitoring.snapshot?.extensions ?? [], findings: monitoring.extensionFindings,
            acceptedIDs: monitoring.acceptedExtensionIDs, filter: filter, query: query,
            coverage: appModel.presentation?.coverage[.extensions]
        )
        let now = Date.now
        let verdict = presentation.verdict(now: now)
        VStack(spacing: 0) {
            StatusLine(verdict: verdict.title, finding: verdict.level != .calm, items: verdict.statusItems,
                       facts: verdict.facts)
                .padding([.horizontal, .top], InstrumentSpacing.page)
            ExtensionBoard(
                content: ExtensionBoardMapping.content(presentation, now: now), query: $query, filter: $filter,
                filters: ExtensionFilter.allCases.map { ($0, $0.title) }, selection: $selection
            ) {
                if let row = presentation.row(withID: selection) {
                    ExtensionDetailView(detail: presentation.detail(of: row), appModel: appModel)
                        .id(row.id)
                } else {
                    ExtensionNoSelection()
                }
            } empty: {
                ExtensionsEmptyState(hasSnapshot: monitoring.snapshot != nil, hasExtensions: !presentation.all.isEmpty,
                                     query: query, notice: presentation.notice(now: now)) { filter = .all }
            }
        }
        .instrumentBackground()
        // Sprung mit Befund-Filter (Kachel „Auffällig“, Hinweis über anderen Listen): einmal übernehmen; danach gilt die
        // Wahl in der Ansicht.
        .onChange(of: window.filter(for: .extensions).findings, initial: true) { _, findings in
            guard findings.isActive else { return }
            filter = ExtensionFilter(findings: findings)
            window.filters[.extensions] = nil
        }
        .onChange(of: window.focusedRecordID, initial: true) { _, recordID in
            guard let recordID else { return }
            filter = .all
            query = ""
            selection = recordID
        }
    }
}

/// Über der leeren Tabelle: erster Scan, unvollständige Prüfung (keine Entwarnung), Suche oder Filter ohne Treffer.
private struct ExtensionsEmptyState: View {
    let hasSnapshot: Bool
    let hasExtensions: Bool
    let query: String
    let notice: String?
    let resetFilter: () -> Void

    var body: some View {
        if !hasSnapshot {
            ProgressView("Erster Scan läuft …")
        } else if !hasExtensions {
            ContentUnavailableView {
                Label("Nicht vollständig geprüft", systemImage: MainSection.extensions.systemImage)
            } description: {
                Text(verbatim: notice ?? "")
            }
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            NoFilterMatchesView(description: "Keine Erweiterung passt zum gewählten Filter.", reset: resetFilter)
        }
    }
}
