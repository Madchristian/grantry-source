import ManagerKit
import SwiftUI

/// Übersicht (Spec §6, Layout „Dashboard zuerst“): Hinweis auf fehlende Voraussetzungen, fünf Kacheln und die
/// zuletzt geänderten Einträge; darunter je nicht vollständig geprüftem Bereich dessen Scan-Abdeckung (#142).
struct DashboardView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    @Environment(MainWindowModel.self) private var window
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                if let presentation = appModel.presentation {
                    tiles(presentation)
                    ObservationBox(observations: appModel.observations)
                    RecentChangesBox(
                        events: presentation.metrics.recentChanges,
                        hasIncompleteCoverage: appModel.monitoring.snapshot?.hasIncompleteCoverage ?? false
                    )
                    notices
                } else {
                    notices
                    firstScanPlaceholder
                }
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Kacheln

    /// Alle fünf Kacheln in einer Reihe, wenn sie mit ihrer Idealbreite Platz haben (`MetricTile.idealWidth`),
    /// sonst drei Spalten (3 + 2) – so steht nie eine letzte Kachel allein.
    private func tiles(_ presentation: PresentationSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Self.tileSpacing) { tileViews(presentation) }
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.tileSpacing), count: 3),
                      spacing: Self.tileSpacing) {
                tileViews(presentation)
            }
        }
    }

    private static let tileSpacing: CGFloat = 16

    @ViewBuilder
    private func tileViews(_ presentation: PresentationSnapshot) -> some View {
        let metrics = presentation.metrics
        let flaggedSection: MainSection = switch presentation.flaggedArea {
        case .permissions: .permissions
        case .autostart: .autostart
        case .apps: .apps
        case .agents: .agents
        case .network: .network
        }
        let exposedCount = presentation.network.exposedCount
        MetricTile(
            title: String(localized: "Apps mit Zugriff"),
            caption: String(localized: "mit mindestens einer erteilten Berechtigung"),
            value: metrics.appsWithAccess,
            systemImage: "app.badge.checkmark",
            tone: nil,
            hint: String(localized: "Zeigt die Berechtigungen nach App.")
        ) { window.show(.permissions) }
        MetricTile(
            title: String(localized: "Neu seit 7 Tagen"),
            caption: String(localized: "neue Apps, Berechtigungen, Autostart und Agenten"),
            value: metrics.newSince7Days,
            systemImage: "sparkles",
            tone: metrics.newSince7Days > 0 ? .positive : nil,
            hint: String(localized: "Zeigt den Verlauf.")
        ) { window.show(.history) }
        MetricTile(
            title: String(localized: "Auffällig"),
            caption: metrics.flaggedCaption,
            accessibilityCaption: metrics.flaggedAccessibilityCaption,
            value: metrics.flaggedCount,
            systemImage: "exclamationmark.shield",
            tone: metrics.flaggedCount > 0 ? Self.flaggedTone(presentation.highestSeverity) : .positive,
            hint: metrics.flaggedHint
        ) { window.show(flaggedSection, onlyFlagged: metrics.hasFindings) }
        MetricTile(
            title: String(localized: "Sicherheit"),
            caption: presentation.security.tileCaption,
            value: presentation.security.hintCount,
            systemImage: "lock.shield",
            tone: presentation.security.tileTone,
            hint: String(localized: "Zeigt den Sicherheitsstatus.")
        ) { window.show(.security) }
        MetricTile(
            title: String(localized: "Von außen erreichbar"),
            caption: Self.exposedCaption(exposedCount),
            value: exposedCount,
            systemImage: MainSection.network.systemImage,
            tone: exposedCount > 0 ? .warning : nil,
            hint: String(localized: "Zeigt die von außen erreichbaren Netzwerkdienste.")
        ) { window.show(.network, onlyFlagged: true) }
    }

    /// Unterzeile der Kachel „Von außen erreichbar“.
    private static func exposedCaption(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "Keine Dienste aus dem Netz erreichbar")
        case 1: String(localized: "Dienst nimmt Verbindungen aus dem Netz an")
        default: String(localized: "Dienste nehmen Verbindungen aus dem Netz an")
        }
    }

    /// Rot bei hohem, sonst Orange; nur für auffällige Einträge (mittel oder hoch) – Hinweise allein bleiben Grün.
    private static func flaggedTone(_ severity: RiskFinding.Severity?) -> PresentationTone {
        severity == .high ? .critical : .warning
    }

    // MARK: - Hinweise

    /// Fehler der Ablage und die Abdeckung jedes nicht vollständig geprüften Bereichs – derselbe Baustein wie über den
    /// Listen, mit Bereichsname und Sprung dorthin.
    @ViewBuilder
    private var notices: some View {
        let incomplete = appModel.presentation?.coverage.incomplete ?? []
        if appModel.storeError != nil || !incomplete.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let storeError = appModel.storeError {
                    NoticeLabel(text: storeError)
                }
                ForEach(incomplete) { coverage in
                    AreaCoverageBar(coverage: coverage, showsArea: true) { window.show(MainSection(coverage.area)) }
                        .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
    }

    private var firstScanPlaceholder: some View {
        ContentUnavailableView {
            Label("Noch keine Daten", systemImage: "magnifyingglass")
        } description: {
            Text(appModel.monitoring.isScanning
                 ? "Der erste Scan läuft. Die Übersicht erscheint, sobald er abgeschlossen ist."
                 : "„Jetzt scannen“ erfasst Berechtigungen und Autostart-Einträge.")
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

/// Einstieg „Installation beobachten“ (#127); während einer Beobachtung deren Status mit „Anzeigen“.
struct ObservationBox: View {
    let observations: ObservationModel
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: MainSection.observations.systemImage)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            if let active = observations.active {
                TimelineView(.everyMinute) { context in
                    Text(verbatim: observations.statusLine(now: context.date) ?? "")
                }
                Spacer(minLength: 8)
                Button("Anzeigen") { window.showObservation(active.id) }
            } else {
                Text("Neues Tool? Beobachte die Installation – Grantry zeigt danach, was hinzugekommen ist, und räumt es auf Wunsch wieder auf.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Installation beobachten …") { window.isObservationStartPresented = true }
                    .disabled(!observations.isAvailable)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}

/// Anklickbare Kachel mit großer Zahl.
struct MetricTile: View {
    /// Idealbreite des Inhalts (ohne Innenabstand): Fünf Kacheln passen so in die volle Breite der Übersicht
    /// (5 × (140 + 32) + 4 × 16 = 924 pt ≤ 960 pt), bei schmalerem Fenster weicht `DashboardView` auf drei Spalten aus.
    static let idealWidth: CGFloat = 140

    let title: String
    let caption: String
    /// VoiceOver-Fassung von `caption`; `nil`: wie `caption`.
    var accessibilityCaption: String? = nil
    let value: Int
    let systemImage: String
    /// `nil`: Zahl in der Standardfarbe.
    let tone: PresentationTone?
    /// VoiceOver-Hinweis, was ein Klick bewirkt.
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(tone?.color ?? .accentColor)
                        .accessibilityHidden(true)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Text(value, format: .number)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(tone?.color ?? .primary)
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)  // als Wert der Kachel, nicht zusätzlich als Text
                Text(title)
                    .font(.headline)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(idealWidth: Self.idealWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .contentShape(.rect)
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title), \(accessibilityCaption ?? caption)"))
        .accessibilityValue(Text(value, format: .number))
        .accessibilityHint(Text(hint))
    }
}

/// Kartenhintergrund mit Hover- und Klick-Rückmeldung.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(.background.secondary, in: .rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isHovered ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor))
                }
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
    }
}

/// Die zuletzt geänderten Einträge; ein Klick zeigt den Eintrag in seiner Liste.
/// Ohne Änderungen nur dann „keine Änderungen“, wenn alle Quellen vollständig gelesen wurden (`CoverageTexts`).
struct RecentChangesBox: View {
    let events: [HistoryEvent]
    let hasIncompleteCoverage: Bool
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Zuletzt geändert")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Verlauf anzeigen") { window.show(.history) }
                    .buttonStyle(.link)
            }
            VStack(spacing: 0) {
                if events.isEmpty {
                    Text(verbatim: CoverageTexts.noChanges(hasIncompleteCoverage: hasIncompleteCoverage))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ForEach(events) { event in
                        Button { window.show(event) } label: {
                            ChangeRow(event: event)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if event.id != events.last?.id {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)) }
        }
    }
}

/// Dezenter Hinweis (z. B. Quellenfehler).
struct NoticeLabel: View {
    let text: String
    var systemImage = PresentationTone.warning.systemImage
    var color = PresentationTone.warning.color

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
