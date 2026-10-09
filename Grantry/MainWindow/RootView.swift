import ManagerKit
import SwiftUI

/// Hauptfenster: Sidebar mit den Bereichen, Detail je Bereich, Symbolleiste mit Scan und Prüfzeitpunkt.
struct RootView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    @Bindable var onboarding: OnboardingModel
    let navigator: MainWindowNavigator
    let whatsNew: WhatsNewModel
    @State private var window = MainWindowModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var didCheckPrerequisites = false
    #if DEBUG
    @State private var didShowRemovalPreview = false
    #endif

    var body: some View {
        @Bindable var window = window
        NavigationSplitView {
            SidebarView(selection: $window.section, unreadCount: appModel.monitoring.unreadCount)
                .navigationSplitViewColumnWidth(
                    min: WindowLayout.sidebarMin, ideal: WindowLayout.sidebarIdeal, max: WindowLayout.sidebarMax
                )
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: WindowLayout.contentMin, ideal: WindowLayout.contentMin)
                .navigationTitle(window.section.title)
                .navigationSubtitle(ScanStatusText.subtitle(for: appModel.monitoring))
                .toolbar {
                    ScanToolbarItem(isScanning: appModel.monitoring.isScanning) {
                        Task { await appModel.scanNow() }
                    }
                }
        }
        .sheet(isPresented: $onboarding.isPresented) {
            OnboardingView(appModel: appModel, prerequisites: prerequisites, onboarding: onboarding)
        }
        .sheet(item: $window.removalRequest) { request in
            RemovalSheet(request: request, appModel: appModel)
        }
        .sheet(isPresented: $window.isObservationStartPresented) {
            ObservationStartSheet(observations: appModel.observations) { window.showObservation($0) }
        }
        .environment(window)
        .environment(\.coverageSteps, coverageSteps)
        .onChange(of: onboarding.isPresented, initial: true) { _, isPresented in window.isOnboardingPresented = isPresented }
        .task {
            await checkPrerequisites()
            didCheckPrerequisites = true
        }
        .onChange(of: canPresentWhatsNew) { _, canPresent in
            guard ReleaseHighlights.current != nil else { return }
            if whatsNew.presentIfNeeded(canPresent: canPresent) {
                openWindow(id: GrantryApp.whatsNewWindowID)
            }
        }
        .onChange(of: navigator.request, initial: true) { _, request in
            guard let request else { return }
            window.show(request)
            if request.opensSelfUninstall, let app = appModel.ownApp { window.requestRemoval(of: app) }
            navigator.request = nil
        }
        #if DEBUG
        .onChange(of: appModel.presentation?.installedApps.count, initial: true) { _, _ in showRemovalPreviewIfRequested() }
        #endif
    }

    private var canPresentWhatsNew: Bool {
        didCheckPrerequisites && scenePhase == .active && !onboarding.isPresented && !window.presentsSheet
    }

    /// Nächste Schritte der Abdeckungshinweise (#142): Festplattenvollzugriff in den Systemeinstellungen, sonst die
    /// Einrichtung bzw. ein neuer Scan.
    private var coverageSteps: CoverageStepHandler {
        CoverageStepHandler(
            missingSetupSteps: prerequisites.missingSetupSteps, isScanning: appModel.monitoring.isScanning
        ) { [appModel, prerequisites, onboarding] step in
            switch step {
            case .setUp(.fullDiskAccess): Task { await prerequisites.perform(.openFullDiskAccessSettings) }
            case .setUp: onboarding.present()
            case .rescan: Task { await appModel.scanNow() }
            }
        }
    }

    #if DEBUG
    /// Öffnet einmalig das Entfernen-Blatt der App aus `-DebugRemovalPreview` (nur ansehen, Bildschirmprüfung – die
    /// Bestätigung bleibt gesperrt, `RemovalRequest.isPreview`).
    private func showRemovalPreviewIfRequested() {
        guard !didShowRemovalPreview, let bundleID = DevelopmentLaunchOptions.removalPreviewBundleID,
              let app = appModel.presentation?.installedApps.first(where: { $0.bundleID == bundleID }) else { return }
        didShowRemovalPreview = true
        window.show(app)
        window.requestRemoval(of: app, mode: DevelopmentLaunchOptions.removalPreviewMode, isPreview: true)
    }
    #endif

    /// Prüft die Einrichtung und zeigt das Onboarding, wenn nötig – beim ersten Start sofort, sonst sobald feststeht,
    /// dass ein erforderlicher Schritt fehlt.
    private func checkPrerequisites() async {
        #if DEBUG
        if DevelopmentLaunchOptions.showsMenuBarContent {
            openWindow(id: DevelopmentLaunchOptions.menuBarPreviewWindowID)
        }
        guard !DevelopmentLaunchOptions.suppressesOnboarding else { return await prerequisites.refresh() }
        #endif
        onboarding.presentIfNeeded(prerequisites.checklist)
        await prerequisites.refresh()
        onboarding.presentIfNeeded(prerequisites.checklist)
    }

    @ViewBuilder
    private var detail: some View {
        switch window.section {
        case .overview: DashboardView(appModel: appModel, prerequisites: prerequisites, onboarding: onboarding)
        case .apps: AppsView(appModel: appModel)
        case .cleanup: CleanupView(appModel: appModel)
        case .observations: ObservationsView(appModel: appModel)
        case .permissions: PermissionsView(appModel: appModel)
        case .autostart: AutostartView(appModel: appModel)
        case .network: NetworkSectionView(appModel: appModel, prerequisites: prerequisites)
        case .agents: AgentsView(appModel: appModel)
        case .security: SecurityView(appModel: appModel, prerequisites: prerequisites)
        case .history: HistoryView(appModel: appModel)
        }
    }
}

/// Sidebar mit den Bereichen; „Verlauf“ trägt die Zahl ungelesener Änderungen.
struct SidebarView: View {
    @Binding var selection: MainSection
    let unreadCount: Int

    var body: some View {
        List(selection: $selection) {
            ForEach(MainSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(section == .history ? unreadCount : 0)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
    }
}

/// Texte zum Scan-Zustand (Untertitel des Fensters).
enum ScanStatusText {
    static func subtitle(for state: MonitoringState, now: Date = .now) -> String {
        if state.isScanning { return String(localized: "Scan läuft …") }
        guard let lastCheckedAt = state.lastCheckedAt else { return String(localized: "Noch kein Scan durchgeführt") }
        return lastChecked(lastCheckedAt, now: now)
    }

    /// „Zuletzt geprüft: 10:50“, an einem anderen Tag mit Datum – gemeinsam für Scan und Update-Prüfung.
    static func lastChecked(_ date: Date, now: Date = .now) -> String {
        let time = Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Zuletzt geprüft: \(time)")
    }
}
