import AppKit
import ManagerKit
import SwiftUI

/// Popover der Menüleiste (Spec §6): Status, die letzten fünf Änderungen und die wichtigsten Befehle.
struct MenuBarContent: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    let navigator: MainWindowNavigator
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
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Scan läuft")
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
                        Button(UpdateTexts.download) { updates.openDownload(update) }
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
                        ProgressView().controlSize(.small).accessibilityLabel("Abschließender Scan läuft")
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
        HStack {
            Button("Hauptfenster öffnen") { showMainWindow() }
                .keyboardShortcut(.defaultAction)
            Button("Jetzt scannen") { Task { await appModel.scanNow() } }
                .disabled(appModel.monitoring.isScanning)
            Spacer()
            Button("Beenden") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    /// Öffnet das Hauptfenster (oder holt es nach vorn) und führt danach `then` aus.
    private func showMainWindow(then: () -> Void = {}) {
        openWindow(id: GrantryApp.mainWindowID)
        NSApp.activate()
        then()
    }
}
