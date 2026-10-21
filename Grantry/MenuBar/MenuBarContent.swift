import AppKit
import ManagerKit
import SwiftUI

/// Popover der Menüleiste (Spec §6): Status, die letzten fünf Änderungen und die wichtigsten Befehle.
struct MenuBarContent: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    let navigator: MainWindowNavigator
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            notices
            Divider()
            observation
            Divider()
            recentChanges
            Divider()
            commands
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grantry")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(ScanStatusText.subtitle(for: appModel.monitoring))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if appModel.monitoring.isScanning {
                ScanProgressView(progress: appModel.monitoring.scanProgress)
                    .frame(width: 180)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        let incompleteCoverage = appModel.presentation?.coverage.incomplete ?? []
        let missing = prerequisites.missingPrerequisitesText
        let securityLine = appModel.presentation?.security.menuBarStatusLine
        if appModel.storeError != nil || !incompleteCoverage.isEmpty || missing != nil || securityLine != nil
            || updates.availableUpdate != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let update = updates.availableUpdate {
                    NoticeLabel(text: update.availabilityText, systemImage: UpdateBanner.systemImage, color: .accentColor)
                    HStack(spacing: 12) {
                        Button(updates.downloadButtonTitle) { updates.openDownload(update) }
                        if update.hasReleaseNotes {
                            Button(UpdateTexts.releaseNotes) { updates.openReleaseNotes(update) }
                        }
                    }
                    .buttonStyle(.link)
                }
                if let securityLine {
                    Label {
                        Text(verbatim: securityLine).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: PresentationTone.critical.systemImage)
                            .foregroundStyle(PresentationTone.critical.color)
                    }
                    .font(.callout)
                    Button("Sicherheit anzeigen …") { navigator.show(.security) }
                        .buttonStyle(.link)
                }
                if let missing {
                    NoticeLabel(text: missing)
                    if prerequisites.isFullDiskAccessMissing {
                        Button("Festplattenvollzugriff öffnen …") {
                            Task { await prerequisites.perform(.openFullDiskAccessSettings) }
                        }
                        .buttonStyle(.link)
                    }
                    Button("Einrichtung öffnen …") { showMainWindow { onboarding.present() } }
                        .buttonStyle(.link)
                }
                if let storeError = appModel.storeError {
                    NoticeLabel(text: storeError)
                }
                // Je nicht vollständig geprüftem Bereich die Zustandszeile der Abdeckung (#142); Gründe im Hauptfenster.
                ForEach(incompleteCoverage) { coverage in
                    NoticeLabel(text: coverage.summaryLine(now: .now), systemImage: coverage.systemImage,
                                color: coverage.tone.color)
                }
            }
        }
    }

    /// Laufende Beobachtung (#127) mit Status und „Beenden“, sonst der Einstieg „Installation beobachten …“.
    @ViewBuilder
    private var observation: some View {
        let observations = appModel.observations
        if observations.active != nil {
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.everyMinute) { context in
                    if let line = observations.statusLine(now: context.date) {
                        NoticeLabel(text: line, systemImage: MainSection.observations.systemImage, color: .accentColor)
                    }
                }
                HStack(spacing: 12) {
                    Button("Beobachtung beenden") {
                        Task {
                            if let finished = await observations.finish() { navigator.showObservation(finished.id) }
                        }
                    }
                    .disabled(observations.isBusy)
                    Button("Anzeigen …") {
                        if let id = observations.active?.id { navigator.showObservation(id) }
                    }
                    if observations.phase == .finishing {
                        ScanProgressView(progress: appModel.monitoring.scanProgress)
                            .frame(width: 180)
                    }
                }
                .buttonStyle(.link)
            }
        } else {
            Button("Installation beobachten …") { navigator.showObservationStart() }
                .buttonStyle(.link)
                .disabled(!observations.isAvailable)
                .help("Hält den aktuellen Stand fest und zeigt später, was ein Tool eingerichtet hat.")
        }
    }

    private var recentChanges: some View {
        let events = appModel.presentation?.metrics.recentChanges ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("Letzte Änderungen")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if events.isEmpty {
                Text(verbatim: appModel.presentation == nil
                    ? String(localized: "Noch kein Scan durchgeführt.")
                    : CoverageTexts.noChanges(hasIncompleteCoverage: appModel.monitoring.snapshot?.hasIncompleteCoverage ?? false))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    ChangeRow(event: event)
                }
            }
        }
    }

    private var commands: some View {
        MenuBarCommands(
            isScanning: appModel.monitoring.isScanning,
            hasReleaseHighlights: ReleaseHighlights.current != nil,
            showMainWindow: { showMainWindow() },
            scan: { Task { await appModel.scanNow() } },
            settings: {
                openSettings()
                NSApp.activate()
            },
            whatsNew: {
                openWindow(id: GrantryApp.whatsNewWindowID)
                NSApp.activate()
            },
            quit: { NSApp.terminate(nil) }
        )
    }

    /// Öffnet das Hauptfenster (oder holt es nach vorn) und führt danach `then` aus.
    private func showMainWindow(then: () -> Void = {}) {
        openWindow(id: GrantryApp.mainWindowID)
        NSApp.activate()
        then()
    }
}

/// Befehle ohne App-Abhängigkeiten; Aktionen und Verfügbarkeit liefert der Aufrufer.
private struct MenuBarCommands: View {
    let isScanning: Bool
    let hasReleaseHighlights: Bool
    let showMainWindow: () -> Void
    let scan: () -> Void
    let settings: () -> Void
    let whatsNew: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Native macOS-Buttons kürzen Text einzeilig: bei Platzmangel ganze Zeilen verwenden.
            ViewThatFits(in: .horizontal) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow { mainWindowButton; scanButton }
                    GridRow { settingsButton; whatsNewButton }
                }
                VStack(spacing: 10) {
                    mainWindowButton
                    scanButton
                    settingsButton
                    whatsNewButton
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Beenden", action: quit)
                    .keyboardShortcut("q")
            }
        }
    }

    private var mainWindowButton: some View {
        Button(action: showMainWindow) { commandLabel("Hauptfenster öffnen") }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    private var scanButton: some View {
        Button(action: scan) { commandLabel("Jetzt scannen") }
            .disabled(isScanning)
    }

    private var settingsButton: some View {
        Button(action: settings) { commandLabel("Einstellungen …") }
    }

    private var whatsNewButton: some View {
        Button(action: whatsNew) { commandLabel("Was ist neu?") }
            .disabled(!hasReleaseHighlights)
    }

    private func commandLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}
