import AppKit
import ManagerKit
import SwiftUI
import UserNotifications

/// Die App: ein einzelnes Hauptfenster, die Menüleiste und die Einstellungen. Die Überwachung startet beim App-Start
/// und läuft weiter, wenn das Fenster geschlossen ist; die Menüleiste bleibt dann erreichbar, und ein Klick aufs
/// Dock-Symbol öffnet das Fenster wieder. Gestartet wird über `AppLauncher` (nur eine Instanz).
struct GrantryApp: App {
    static let mainWindowID = "main"
    static let whatsNewWindowID = "whats-new"

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Grantry", id: Self.mainWindowID) {
            RootView(
                appModel: appDelegate.appModel, prerequisites: appDelegate.prerequisites,
                onboarding: appDelegate.onboarding, navigator: appDelegate.navigator, whatsNew: appDelegate.whatsNew
            )
                .environment(appDelegate.updates)
                .frame(minWidth: WindowLayout.windowMinWidth, minHeight: WindowLayout.windowMinHeight)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            ScanCommands(appModel: appDelegate.appModel)
            ObservationCommands(appModel: appDelegate.appModel, navigator: appDelegate.navigator)
            AppCommands()
            UninstallCommands(appModel: appDelegate.appModel, navigator: appDelegate.navigator)
            UpdateCommands(updates: appDelegate.updates)
            WhatsNewCommands()
            #if DEBUG
            DevelopmentCommands(tools: appDelegate.developmentTools)
            #endif
        }

        MenuBarExtra {
            MenuBarContent(
                appModel: appDelegate.appModel, prerequisites: appDelegate.prerequisites,
                onboarding: appDelegate.onboarding, navigator: appDelegate.navigator
            )
            .environment(appDelegate.updates)
        } label: {
            MenuBarLabel(appModel: appDelegate.appModel, navigator: appDelegate.navigator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(prerequisites: appDelegate.prerequisites, dockVisibility: appDelegate.dockVisibility)
                .environment(appDelegate.updates)
        }

        Window("Was ist neu?", id: Self.whatsNewWindowID) {
            if let content = ReleaseHighlights.current {
                WhatsNewView(content: content, model: appDelegate.whatsNew)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        #if DEBUG
        Window("Menüleiste (Vorschau)", id: DevelopmentLaunchOptions.menuBarPreviewWindowID) {
            MenuBarContent(
                appModel: appDelegate.appModel, prerequisites: appDelegate.prerequisites,
                onboarding: appDelegate.onboarding, navigator: appDelegate.navigator
            )
            .environment(appDelegate.updates)
        }
        .windowResizability(.contentSize)
        #endif
    }
}

/// „Jetzt scannen“ (⌘R) im Menü „Darstellung“.
struct ScanCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Jetzt scannen") { Task { await appModel.scanNow() } }
                .keyboardShortcut("r")
                .disabled(appModel.monitoring.isScanning)
        }
    }
}

/// „Installation beobachten …“ bzw. „Beobachtung beenden“ im Menü „Ablage“ (#127).
struct ObservationCommands: Commands {
    let appModel: AppModel
    let navigator: MainWindowNavigator

    var body: some Commands {
        CommandGroup(after: .newItem) {
            let observations = appModel.observations
            if observations.active == nil {
                Button("Installation beobachten …") { navigator.showObservationStart() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!observations.isAvailable)
            } else {
                Button("Beobachtung beenden") {
                    Task {
                        if let finished = await observations.finish() { navigator.showObservation(finished.id) }
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(observations.isBusy)
            }
        }
    }
}

/// Besitzt die app-weiten Modelle, damit sie unabhängig vom Fenster leben, startet die Überwachung und zeigt
/// Benachrichtigungen auch, während die App im Vordergrund ist; ein Klick auf eine Benachrichtigung öffnet ihr Ziel
/// (`NotificationDestination`): bei einer Sicherheitsprüfung deren Bereich, sonst – auch bei der Sammelmeldung – den
/// Verlauf (Spec §7).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    let updates: UpdateModel
    let whatsNew: WhatsNewModel
    let navigator = MainWindowNavigator()
    private var dockWindowToRestore: NSWindow?
    private var dockRestoreExpiry: Task<Void, Never>?
    lazy var dockVisibility = DockVisibilityModel { [weak self] visible in
        self?.applyDockVisibility(visible) ?? false
    }
    #if DEBUG
    let developmentTools: DevelopmentTools
    #endif

    override init() {
        whatsNew = WhatsNewModel(version: InstalledBuild.current().version,
                                hasCompletedOnboarding: UserDefaults.standard.bool(forKey: OnboardingModel.completedKey))
        let appModel = AppModel(storage: LaunchOptions.storage)
        self.appModel = appModel
        let scan: @MainActor () -> Void = { Task { await appModel.scanNow() } }
        let listenerSchedule = appModel.listenerSchedule
        prerequisites = PrerequisitesModel(
            helperClient: appModel.helperClient, helperActivity: appModel.helperActivity,
            abandonRunningAction: { await appModel.actions.abandonRunningAction() },
            afterHelperRegistration: { listenerSchedule.reset() },
            // Auch eine Genehmigung in den Systemeinstellungen (ohne erneute Registrierung) macht den Helper verfügbar:
            // Der Lauscher-Takt wird zurückgesetzt, damit der Scan ihn sofort fragt statt erst nach bis zu 15 min.
            onPrerequisiteBecameAvailable: {
                listenerSchedule.reset()
                scan()
            }
        )
        let openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
        #if DEBUG
        let feedURL = DevelopmentLaunchOptions.updateFeedURL
        let updates = UpdateModel(
            checker: UpdateChecker(feedURL: feedURL ?? UpdateFeed.url), checksAutomatically: feedURL != nil,
            openURL: openURL
        )
        #else
        let updates = UpdateModel(checksAutomatically: true, openURL: openURL)
        #endif
        self.updates = updates
        let finishOnboarding: @MainActor () -> Void = {
            updates.commitOnboardingChoice()
            scan()
        }
        #if DEBUG
        onboarding = OnboardingModel(
            forcesPresentation: DevelopmentLaunchOptions.showsOnboarding,
            needsUpdateDecision: { updates.isDecisionPending }, onFinish: finishOnboarding
        )
        #else
        onboarding = OnboardingModel(needsUpdateDecision: { updates.isDecisionPending }, onFinish: finishOnboarding)
        #endif
        #if DEBUG
        developmentTools = DevelopmentTools(helperClient: appModel.helperClient)
        #endif
        super.init()
    }

    private func applyDockVisibility(_ visible: Bool) -> Bool {
        dockRestoreExpiry?.cancel()
        dockWindowToRestore = nil
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        // AppKit returns false for an unchanged policy. It is already applied, even
        // when an external activation has made it differ from the saved preference.
        guard NSApp.activationPolicy() != policy else { return true }
        if NSApp.isActive, let window = NSApp.keyWindow {
            dockWindowToRestore = window
            // Some OS versions do not deactivate on a policy change. Never keep a pending
            // restoration that could steal focus on a later, intentional app switch.
            dockRestoreExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.dockWindowToRestore = nil
            }
        }
        let applied = NSApp.setActivationPolicy(policy)
        if !applied {
            dockRestoreExpiry?.cancel()
            dockWindowToRestore = nil
        }
        return applied
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard let window = dockWindowToRestore else { return }
        dockWindowToRestore = nil
        dockRestoreExpiry?.cancel()
        // AppKit deactivates asynchronously after regular → accessory; the next main-queue
        // turn after setActivationPolicy is still too early. Wait for the actual event.
        DispatchQueue.main.async {
            NSApp.unhideWithoutActivation()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            // This restores focus lost by the user's own policy toggle. Cooperative activate()
            // can be refused after AppKit has already handed activation to the previous app.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        dockVisibility.applyCurrentVisibility()
    }

    /// Startet die Überwachung – in Release-Builds erst, nachdem die Registrierung des Helpers nach einem Austausch
    /// des App-Bundles erneuert ist (`PrerequisitesModel.renewHelperRegistrationIfNeeded()`); verlangt sie eine
    /// Genehmigung, erscheint die Einrichtung. Debug-Builds (Xcode, UI-Tests) registrieren nie von selbst um, sonst
    /// zeigte der Helper des Systems auf einen Build aus DerivedData. Nach jedem Scan wird die Einrichtung erneut
    /// geprüft, wenn etwas fehlt oder eine abhängige Quelle ausfiel.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        appModel.onNewSnapshot = { [prerequisites] snapshot in
            Task { await prerequisites.recheck(after: snapshot) }
        }
        updates.start()
        Task {
            #if !DEBUG
            if await prerequisites.renewHelperRegistrationIfNeeded() {
                onboarding.presentIfNeeded(prerequisites.checklist)
            }
            #endif
            await appModel.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Vor dem Beenden laufende Aktionen abschließen (ein Entfernen verlöre sonst seinen Wiederherstellungsbeleg),
    /// dann die Überwachung stoppen und wartende Benachrichtigungen noch zustellen.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SingleInstance.markTerminating()
        updates.stop()
        Task {
            await appModel.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let destination = NotificationDestination(userInfo: response.notification.request.content.userInfo) ?? .history
        await navigator.show(destination: destination)
    }
}
