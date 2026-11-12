import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

/// Menüleisten-Menü im Lagebild (LB-5.4, #555; Entwurf LB-5.1, #552; Spec 2026-11-10 § 11 Entscheidung 7, § 11.5):
/// Lagezeile mit Schild und Urteil wie die Übersicht (`DashboardVerdict`), während eines Scans sein Fortschritt, Hinweise,
/// Beobachtung (immer als Panel), die letzten fünf Änderungen und die Befehle. Liest nur aus den Modellen; zeichnet bei
/// Scan, Beobachtung, Update und neuen Änderungen. Aktionen, Sperren und Texte der Befehle wie bisher.
struct MenuBarContent: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    let navigator: MainWindowNavigator
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarMenu {
            verdictBar
            if appModel.monitoring.isScanning {
                MenuBarScanProgress(progress: appModel.monitoring.scanProgress)
            }
            MenuBarNotices(appModel: appModel, prerequisites: prerequisites, navigator: navigator) {
                showMainWindow { onboarding.present() }
            }
            MenuBarObservation(observations: appModel.observations, scanProgress: appModel.monitoring.scanProgress,
                               navigator: navigator)
            MenuBarRecentChanges(
                events: appModel.presentation?.metrics.recentChanges ?? [],
                emptyText: appModel.presentation == nil
                    ? String(localized: "Noch kein Scan durchgeführt.")
                    : CoverageTexts.noChanges(
                        hasIncompleteCoverage: appModel.monitoring.snapshot?.hasIncompleteCoverage ?? false))
        } commands: {
            commands
        }
    }

    private var verdictBar: some View {
        let monitoring = appModel.monitoring
        let verdict = appModel.presentation.map { DashboardVerdict($0, scannedAt: monitoring.snapshot?.takenAt) }
            ?? .notScanned(isScanning: monitoring.isScanning)
        // Ohne Chips und mit knappen Kenndaten: 380 breit (Entwurf LB-5.1); Einzelheiten stehen in den Hinweisen.
        return VerdictBar(verdict: verdict.title, reason: verdict.reason, shield: verdict.shield.shieldForm, items: [],
                          facts: MenuBarMenuTexts.facts(isScanning: monitoring.isScanning,
                                                        scannedAt: monitoring.lastCheckedAt))
    }

    private var commands: some View {
        MenuBarCommandBar(
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

/// Fortschritt des laufenden Scans als Spur im Panel; Restdauer wie bisher aus `ScanProgressText`.
private struct MenuBarScanProgress: View {
    let progress: ScanProgress

    var body: some View {
        ScanProgressText(progress: progress) { text in
            ProgressSpur(title: String(localized: "Scan läuft"), detail: text,
                         fraction: progress.isIndeterminate ? nil : progress.fraction, tone: .info)
        }
        .instrumentPanel()
    }
}

/// Panel „Hinweise“: Update, kritische Sicherheit, fehlende Voraussetzungen, Fehler der Ablage, Stand der
/// Signaturprüfung und je nicht vollständig geprüftem Bereich die Zustandszeile der Abdeckung (#142); ohne Hinweis nichts.
/// Sprünge wie bisher als Links unter dem Hinweis.
private struct MenuBarNotices: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let navigator: MainWindowNavigator
    let openSetup: () -> Void
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        let incompleteCoverage = appModel.presentation?.coverage.incomplete ?? []
        let missing = prerequisites.missingPrerequisitesText
        let securityLine = appModel.presentation?.security.menuBarStatusLine
        let signature = signatureNote
        let update = updates.availableUpdate
        let count = [update != nil, securityLine != nil, missing != nil, appModel.storeError != nil, signature != nil]
            .filter(\.self).count + incompleteCoverage.count
        if count > 0 {
            let hasFinding = securityLine != nil || missing != nil || appModel.storeError != nil
                || incompleteCoverage.contains { $0.tone != .positive }
            SettingsPanel(String(localized: "Hinweise"), detail: MenuBarMenuTexts.notices(count), finding: hasFinding) {
                if let update {
                    LinkedNote(update.availabilityText, kind: .info) {
                        Button(updates.downloadButtonTitle) { updates.openDownload(update) }
                        if update.hasReleaseNotes {
                            Button(UpdateTexts.releaseNotes) { updates.openReleaseNotes(update) }
                        }
                    }
                }
                if let securityLine {
                    LinkedNote(securityLine, kind: .critical) {
                        Button("Sicherheit anzeigen …") { navigator.show(.security) }
                    }
                }
                if let missing {
                    LinkedNote(missing, kind: .finding) {
                        if prerequisites.isFullDiskAccessMissing {
                            Button("Festplattenvollzugriff öffnen …") {
                                Task { await prerequisites.perform(.openFullDiskAccessSettings) }
                            }
                        }
                        Button("Einrichtung öffnen …", action: openSetup)
                    }
                }
                if let storeError = appModel.storeError {
                    InstrumentNote(storeError, kind: .critical)
                }
                if let signature {
                    InstrumentNote(signature, kind: .info)
                }
                ForEach(incompleteCoverage) { coverage in
                    InstrumentNote(coverage.summaryLine(now: .now), kind: coverage.noteKind)
                }
            }
        }
    }

    /// Stand der Signaturprüfung nach dem Inventarscan (bisher im Kopf).
    private var signatureNote: String? {
        let monitoring = appModel.monitoring
        guard !monitoring.isScanning else { return nil }
        if monitoring.pendingSignatureChecks > 0 || monitoring.signatureChecksTimedOut {
            return ScanStatusText.subtitle(for: monitoring)
        }
        return nil
    }
}

extension AreaCoverage {
    /// Hinweisart der Abdeckung: nicht gelesen als Fehler, teilweise oder zuletzt bekannt als Befund.
    fileprivate var noteKind: InstrumentNote.Kind {
        switch tone {
        case .critical: .critical
        case .warning: .finding
        default: .info
        }
    }
}

/// Panel „Beobachtung“ (#127), immer als Panel (Spec § 11.5 f): ohne laufende Beobachtung der Einstieg, sonst Name,
/// Laufzeit und neue Einträge im Kopf mit „Beobachtung beenden“ und „Anzeigen …“.
private struct MenuBarObservation: View {
    let observations: ObservationModel
    let scanProgress: ScanProgress
    let navigator: MainWindowNavigator

    var body: some View {
        if let active = observations.active {
            // Minutentakt nur für die Laufzeit, wie bisher.
            TimelineView(.everyMinute) { context in
                SettingsPanel(String(localized: "Beobachtung"),
                              detail: MenuBarMenuTexts.observation(name: active.name, startedAt: active.startedAt,
                                                                   now: context.date,
                                                                   addedCount: observations.liveAddedCount)) {
                    MenuBarLinks {
                        Button("Beobachtung beenden") {
                            Task {
                                if let finished = await observations.finish() { navigator.showObservation(finished.id) }
                            }
                        }
                        .disabled(observations.isBusy)
                        Button("Anzeigen …") { navigator.showObservation(active.id) }
                    }
                    if observations.phase == .finishing {
                        ScanProgressView(progress: scanProgress)
                    }
                }
            }
        } else {
            SettingsPanel(String(localized: "Beobachtung"), detail: String(localized: "keine läuft")) {
                MenuBarLinks {
                    Button("Installation beobachten …") { navigator.showObservationStart() }
                        .disabled(!observations.isAvailable)
                        .help("Hält den aktuellen Stand fest und zeigt später, was ein Tool eingerichtet hat.")
                }
            }
        }
    }
}

/// Panel „Letzte Änderungen“: die fünf neuesten mit Symbol der Art ohne Farbe, ungelesen fett (Spec § 11.5 g); ohne
/// Änderungen ein Hinweis. Ein Minutentakt für die relativen Zeiten aller Zeilen (bisher einer je Zeile), ohne
/// Änderungen keiner.
private struct MenuBarRecentChanges: View {
    let events: [HistoryEvent]
    let emptyText: String

    var body: some View {
        if events.isEmpty {
            SettingsPanel(String(localized: "Letzte Änderungen")) { InstrumentNote(emptyText) }
        } else {
            TimelineView(.everyMinute) { context in
                SettingsPanel(String(localized: "Letzte Änderungen"),
                              detail: MenuBarMenuTexts.changes(count: events.count,
                                                               unread: events.count(where: { !$0.isRead }))) {
                    ChangeLines {
                        ForEach(events) { event in
                            let description = ChangeDescription(event.event)
                            ChangeLine(symbol: event.event.kind.rowSymbol, title: description.title,
                                       detail: description.body,
                                       time: RelativeTime.text(for: event.event.detectedAt, now: context.date),
                                       isUnread: !event.isRead)
                        }
                    }
                }
            }
        }
    }
}
