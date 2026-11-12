import GrantryCharts
import ManagerKit
import SwiftUI

/// Übersicht im Lagebild (LB-3.2, #544; Entwurf LB-3.1, #543; Spec 2026-11-10 § 4.3, § 11.3): oben die Banner (fehlende
/// Voraussetzungen, Update) und ein Fehler der Ablage, darunter die Lagezeile mit Urteil (`DashboardVerdict`), die fünf
/// Zählkacheln mit Sprung, bei Lücken das Panel „Abdeckung“ und daneben bzw. darunter „Beobachtung“ und „Letzte
/// Änderungen“. Liest nur aus `AppModel`; zeichnet bei Scan, Beobachtung, Update und Fenstergröße.
struct DashboardView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    @Environment(UpdateModel.self) private var updates
    /// Fünf Kacheln in einer Reihe und die Panels nebeneinander; schmaler drei Spalten und die Panels untereinander.
    @State private var isWide = true

    /// Inhaltsbreite, ab der fünf Zählkacheln nebeneinander passen.
    private static let wideWidth = 5 * InstrumentSize.countTile + 4 * InstrumentSpacing.panel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                banners
                if let storeError = appModel.storeError {
                    InstrumentNote(storeError, kind: .critical)
                }
                verdictBar
                if let presentation = appModel.presentation {
                    DashboardTiles(presentation: presentation, columns: isWide ? 5 : 3)
                    DashboardCoveragePanel(incomplete: presentation.coverage.incomplete)
                    panels(presentation)
                } else {
                    InstrumentEmptyState(
                        symbol: "magnifyingglass", title: String(localized: "Noch keine Daten"),
                        message: appModel.monitoring.isScanning
                            ? String(localized: "Der erste Scan läuft. Die Übersicht erscheint, sobald er abgeschlossen ist.")
                            : String(localized: "„Jetzt scannen“ erfasst Berechtigungen und Autostart-Einträge."))
                        .frame(maxWidth: .infinity, minHeight: InstrumentSize.detailMin)
                        .instrumentPanel()
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideWidth } action: { isWide = $0 }
            .padding(InstrumentSpacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .instrumentBackground()
    }

    @ViewBuilder
    private var banners: some View {
        if let missing = prerequisites.missingPrerequisitesText {
            PrerequisitesBanner(
                text: missing,
                openFullDiskAccess: prerequisites.isFullDiskAccessMissing
                    ? { Task { await prerequisites.perform(.openFullDiskAccessSettings) } } : nil
            ) { onboarding.present() }
        }
        if let update = updates.availableUpdate {
            UpdateBanner(item: update, updates: updates)
        }
    }

    private var verdictBar: some View {
        let verdict = appModel.presentation.map {
            DashboardVerdict($0, scannedAt: appModel.monitoring.snapshot?.takenAt)
        } ?? .notScanned(isScanning: appModel.monitoring.isScanning)
        return VerdictBar(verdict: verdict.title, reason: verdict.reason, shield: verdict.shield.shieldForm,
                          items: verdict.items.map(\.statusItem), facts: verdict.facts)
    }

    @ViewBuilder
    private func panels(_ presentation: PresentationSnapshot) -> some View {
        let observation = ObservationPanel(observations: appModel.observations)
        let changes = RecentChangesPanel(
            events: presentation.metrics.recentChanges,
            hasIncompleteCoverage: appModel.monitoring.snapshot?.hasIncompleteCoverage ?? false)
        if isWide {
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                observation.frame(width: InstrumentSize.columnWide)
                changes
            }
        } else {
            observation
            changes
        }
    }
}

// MARK: - Kacheln

/// Die fünf Zählkacheln (Spec § 11.3 a) mit denselben Sprüngen wie bisher: in einer Reihe oder in drei Spalten (3 + 2).
private struct DashboardTiles: View {
    let presentation: PresentationSnapshot
    let columns: Int
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        JumpTileGrid(columns: columns) {
            ForEach(DashboardTile.tiles(DashboardTile.Facts(presentation))) { tile in
                let target = target(tile.kind)
                JumpTile(title: tile.title, value: tile.value, detail: tile.detail, tone: tile.emphasis.statusTone,
                         destination: target.section.title, hint: target.hint) {
                    window.show(target.section, findings: target.findings)
                }
            }
        }
    }

    /// Bereich, Befund-Filter und VoiceOver-Hinweis des Sprungs – wie bei den bisherigen Kacheln.
    private func target(_ kind: DashboardTile.Kind) -> (section: MainSection, findings: FindingFilter, hint: String) {
        let metrics = presentation.metrics
        return switch kind {
        case .appsWithAccess: (.permissions, .all, String(localized: "Zeigt die Berechtigungen nach App."))
        case .newEntries: (.history, .all, String(localized: "Zeigt den Verlauf."))
        case .flagged: (MainSection(presentation.flaggedArea), metrics.flagged.tileFilter, metrics.flaggedHint)
        case .security: (.security, .all, String(localized: "Zeigt den Sicherheitsstatus."))
        case .exposed: (.network, .flagged, String(localized: "Zeigt die aus dem Netz erreichbaren Netzwerkdienste."))
        }
    }
}

extension DashboardTile.Emphasis {
    var statusTone: StatusTone {
        switch self {
        case .plain: .neutral
        case .new: .info
        case .finding: .finding
        case .calm: .positive
        }
    }
}

// MARK: - Panels

/// Abdeckung der Bereiche, die der letzte Scan nicht vollständig gelesen hat (#142), je mit Sprung und nächstem Schritt;
/// ohne Lücken nichts.
private struct DashboardCoveragePanel: View {
    let incomplete: [AreaCoverage]
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        if !incomplete.isEmpty {
            VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
                PeilHead(String(localized: "Abdeckung"), detail: detail, finding: true)
                ForEach(incomplete) { coverage in
                    AreaCoverageBar(coverage: coverage, showsArea: true) { window.show(MainSection(coverage.area)) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentPanel()
        }
    }

    private var detail: String {
        incomplete.count == 1 ? String(localized: "1 Bereich unvollständig")
            : String(localized: "\(incomplete.count) Bereiche unvollständig")
    }
}

/// Panel „Beobachtung“ (#127): ohne laufende Beobachtung der Einstieg, sonst ihr Stand als Sprungzeile.
private struct ObservationPanel: View {
    let observations: ObservationModel
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        if let active = observations.active {
            // Minutentakt nur für die Laufzeit, wie bisher.
            TimelineView(.everyMinute) { context in
                panel(.running(
                    since: String(localized: "läuft seit \(ObservationTexts.duration(from: active.startedAt, to: context.date))"),
                    value: observations.liveAddedCount.map { String(localized: "\($0) neu") } ?? "",
                    row: InstrumentRowContent(symbol: MainSection.observations.systemImage, title: active.name,
                                              detail: runningDetail(active),
                                              status: StatusItem(String(localized: "läuft"), tone: .info)),
                    destination: MainSection.observations.title))
            }
        } else {
            panel(.idle(message: String(localized: "Neues Tool? Beobachte die Installation – Grantry zeigt danach, was hinzugekommen ist, und räumt es auf Wunsch wieder auf."),
                        isAvailable: observations.isAvailable))
        }
    }

    private func panel(_ state: ObservationOverviewPanel.State) -> some View {
        ObservationOverviewPanel(state: state) { window.isObservationStartPresented = true } show: {
            if let id = observations.active?.id { window.showObservation(id) }
        }
    }

    /// „seit 14:20 · 4 neue Einträge“.
    private func runningDetail(_ active: InstallationObservation) -> String {
        let since = String(localized: "seit \(active.startedAt.formatted(date: .omitted, time: .shortened))")
        guard let added = observations.liveAddedCount else { return since }
        return since + " · " + ObservationTexts.entries(added)
    }
}

/// Panel „Letzte Änderungen“: die neuesten Änderungen als Sprungzeilen zum Eintrag. Ohne Änderungen nur dann „keine
/// Änderungen“, wenn alle Quellen vollständig gelesen wurden (`CoverageTexts`).
private struct RecentChangesPanel: View {
    let events: [HistoryEvent]
    let hasIncompleteCoverage: Bool
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        // Ein Minutentakt für die relativen Zeiten aller Zeilen (bisher einer je Zeile); ohne Änderungen keiner.
        if events.isEmpty {
            panel(now: .now)
        } else {
            TimelineView(.everyMinute) { context in panel(now: context.date) }
        }
    }

    private func panel(now: Date) -> some View {
        RecentChangesOverviewPanel(
            changes: events.map { event in
                RecentChangesOverviewPanel.Change(id: event.id.uuidString, row: event.rowContent(now: now),
                                                  destination: MainSection(showing: event.event).title)
            },
            emptyText: CoverageTexts.noChanges(hasIncompleteCoverage: hasIncompleteCoverage)
        ) {
            window.show(.history)
        } select: { id in
            if let event = events.first(where: { $0.id.uuidString == id }) { window.show(event) }
        }
    }
}

extension HistoryEvent {
    /// Zeile im Panel „Letzte Änderungen“: Text der Änderung als Titel, darunter Art und Zeit, die Änderung als Chip.
    func rowContent(now: Date) -> InstrumentRowContent {
        let description = ChangeDescription(event)
        let title = description.body.split(separator: "\n").first.map(String.init) ?? description.title
        return InstrumentRowContent(
            symbol: event.kind.rowSymbol, title: title,
            detail: description.title + " · " + RelativeTime.text(for: event.detectedAt, now: now),
            status: event.kind.chipItem)
    }
}

extension ChangeEvent.Kind {
    /// Symbol der Änderung in der Zeile (der Kreis kommt von `InstrumentRowIcon`).
    var rowSymbol: String {
        switch self {
        case .added: "plus"
        case .modified: "pencil"
        case .removed: "minus"
        }
    }

    /// Chip der Änderung: „neu“, „geändert“, „entfernt“.
    var chipText: String {
        switch self {
        case .added: String(localized: "neu")
        case .modified: String(localized: "geändert")
        case .removed: String(localized: "entfernt")
        }
    }
}
