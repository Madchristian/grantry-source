import Testing
import Foundation
import ManagerKit

@Suite struct SetupChecklistTests {
    private static let complete = SetupStatus(
        fullDiskAccess: true, helper: .ready, notifications: .authorized, launchAtLogin: .enabled
    )

    @Test func stepsFollowTheOnboardingOrder() {
        let checklist = SetupChecklist(SetupStatus())
        #expect(checklist.items.map(\.step) == [.fullDiskAccess, .helper, .notifications, .launchAtLogin])
        #expect(SetupStep.allCases.filter(\.isRequired) == [.fullDiskAccess, .helper])
    }

    @Test func uncheckedStepsAreNeitherDoneNorMissing() {
        let checklist = SetupChecklist(SetupStatus())
        #expect(checklist.items.allSatisfy { $0.state == .checking && $0.tone == nil && $0.action == nil })
        #expect(checklist.missingRequired.isEmpty)
        #expect(!checklist.isComplete)
        #expect(checklist.nextStep == nil)
        #expect(checklist.bannerText == nil)
    }

    @Test func completeWhenAllRequiredStepsAreDone() {
        let checklist = SetupChecklist(SetupStatus(fullDiskAccess: true, helper: .ready, notifications: .denied))
        #expect(checklist.isComplete)
        #expect(checklist.missingRequired.isEmpty)
        #expect(checklist.nextStep == .notifications)
        #expect(checklist.bannerText == nil)
    }

    @Test func everythingDone() {
        let checklist = SetupChecklist(Self.complete)
        #expect(checklist.items.allSatisfy { $0.state == .done && $0.tone == .positive && $0.action == nil })
        #expect(checklist.nextStep == nil)
    }

    // MARK: - Erneut prüfen nach einem Scan

    private static func snapshot(failing sources: [SourceID]) -> Snapshot {
        Snapshot(takenAt: .now, grants: [], autostartItems: [],
                 sourceErrors: sources.map { SourceError(source: $0, message: "authorization denied") })
    }

    /// Fällt die System-TCC-Quelle (Festplattenvollzugriff) oder die BTM-Quelle (Helper) aus, ist der Zustand der
    /// Einrichtung neu zu prüfen – auch wenn er zuletzt „erledigt“ war (etwa nach dem Austausch des App-Bundles).
    @Test(arguments: [[SourceID.tccSystem], [.btm], [.launchd, .btm]])
    func failingPrerequisiteSourceTriggersRecheck(sources: [SourceID]) {
        #expect(SetupChecklist(Self.complete).shouldRecheck(after: Self.snapshot(failing: sources)))
    }

    @Test func unrelatedFailuresWithCompleteSetupNeedNoRecheck() {
        let checklist = SetupChecklist(Self.complete)
        #expect(!checklist.shouldRecheck(after: Self.snapshot(failing: [])))
        #expect(!checklist.shouldRecheck(after: Self.snapshot(failing: [.launchd, .tccUser, .apps])))
    }

    /// Fehlt etwas nachweislich, wird nach jedem Scan geprüft, ob es inzwischen da ist.
    @Test func missingRequiredStepTriggersRecheck() {
        var status = Self.complete
        status.fullDiskAccess = false
        #expect(SetupChecklist(status).shouldRecheck(after: Self.snapshot(failing: [])))
    }

    @Test func missingFullDiskAccessOpensSettings() throws {
        var status = Self.complete
        status.fullDiskAccess = false
        let checklist = SetupChecklist(status)
        let item = try #require(checklist.item(for: .fullDiskAccess))
        #expect(item.state == .open)
        #expect(item.text == "Nicht erteilt")
        #expect(item.action == .openFullDiskAccessSettings)
        #expect(!checklist.isComplete)
        #expect(checklist.nextStep == .fullDiskAccess)
        #expect(checklist.bannerText == "Festplattenvollzugriff fehlt. Ohne sie bleiben Teile des Systems ungeprüft.")
    }

    @Test(arguments: [
        (HelperState.notInstalled, SetupChecklist.State.open, SetupChecklist.Action?.some(.helper(.install))),
        (.awaitingApproval, .open, .helper(.approve)),
        (.outdated(installed: 1, expected: 2), .open, .helper(.reinstall)),
        (.unreachable("Zeitüberschreitung"), .open, .helper(.reinstall)),
        (.missingFromBundle, .blocked, nil),
        (.requiresAdministrator, .blocked, nil),
        (.ready, .done, nil),
    ])
    func helperStateUsesItsPresentation(
        state: HelperState, progress: SetupChecklist.State, action: SetupChecklist.Action?
    ) throws {
        var status = Self.complete
        status.helper = state
        let item = try #require(SetupChecklist(status).item(for: .helper))
        #expect(item.state == progress)
        #expect(item.action == action)
        #expect(item.text == HelperStatePresentation(state).text)
        #expect(item.tone == HelperStatePresentation(state).tone)
    }

    @Test func bannerNamesEveryMissingRequiredStep() {
        let checklist = SetupChecklist(SetupStatus(fullDiskAccess: false, helper: .notInstalled))
        #expect(checklist.missingRequired.map(\.step) == [.fullDiskAccess, .helper])
        #expect(checklist.bannerText == "Festplattenvollzugriff fehlt. Helper: Nicht installiert. "
            + "Ohne sie bleiben Teile des Systems ungeprüft.")
    }

    @Test(arguments: [
        (NotificationAuthorization.notDetermined, SetupChecklist.Action.requestNotifications),
        (.denied, .openNotificationSettings),
    ])
    func openNotificationStepOffersAction(authorization: NotificationAuthorization, action: SetupChecklist.Action) {
        var status = Self.complete
        status.notifications = authorization
        let checklist = SetupChecklist(status)
        #expect(checklist.item(for: .notifications)?.state == .open)
        #expect(checklist.item(for: .notifications)?.action == action)
        #expect(checklist.isComplete)
    }

    @Test func loginItemAwaitingApprovalLinksToLoginItems() {
        var status = Self.complete
        status.launchAtLogin = .requiresApproval
        let item = SetupChecklist(status).item(for: .launchAtLogin)
        #expect(item?.state == .open)
        #expect(item?.action == .openLoginItemSettings)
        status.launchAtLogin = .disabled
        #expect(SetupChecklist(status).item(for: .launchAtLogin)?.action == nil)
    }

    @Test func presentsOnFirstLaunchRegardlessOfStatus() {
        #expect(SetupChecklist(Self.complete).shouldPresentAutomatically(hasCompletedOnboarding: false))
        #expect(SetupChecklist(SetupStatus()).shouldPresentAutomatically(hasCompletedOnboarding: false))
    }

    @Test func presentsAgainOnlyForFixableMissingRequiredSteps() {
        #expect(!SetupChecklist(Self.complete).shouldPresentAutomatically(hasCompletedOnboarding: true))
        #expect(!SetupChecklist(SetupStatus()).shouldPresentAutomatically(hasCompletedOnboarding: true))
        #expect(SetupChecklist(SetupStatus(fullDiskAccess: false, helper: .ready))
            .shouldPresentAutomatically(hasCompletedOnboarding: true))
        #expect(!SetupChecklist(SetupStatus(fullDiskAccess: true, helper: .requiresAdministrator))
            .shouldPresentAutomatically(hasCompletedOnboarding: true))
        // Empfohlene Schritte allein holen das Onboarding nicht zurück.
        #expect(!SetupChecklist(SetupStatus(fullDiskAccess: true, helper: .ready, notifications: .denied, launchAtLogin: .disabled))
            .shouldPresentAutomatically(hasCompletedOnboarding: true))
    }

    @Test func actionTitlesAreGerman() {
        #expect(SetupChecklist.Action.openFullDiskAccessSettings.title == "Einstellungen öffnen")
        #expect(SetupChecklist.Action.helper(.approve).title == "Genehmigen")
        #expect(SetupChecklist.Action.requestNotifications.title == "Erlauben …")
        #expect(SetupChecklist.Action.openLoginItemSettings.title == "Anmeldeobjekte öffnen")
    }
}
