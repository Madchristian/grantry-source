import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

// Nur Attrappen: Kein Test meldet echte Dienste ab oder legt etwas in den Papierkorb.

private enum Fixture {
    static let grantry = TestData.installedApp("Grantry", bundleID: "de.cstrube.Grantry").identity
    static let app = LeftoverCandidate(path: "/Applications/Grantry.app", kind: .appBundle, confidence: .safe)
    static let data = LeftoverCandidate(
        path: "/Users/test/Library/Application Support/Grantry", kind: .applicationSupport, confidence: .safe
    )
    static let preferences = LeftoverCandidate(
        path: "/Users/test/Library/Preferences/de.cstrube.Grantry.plist", kind: .preferences, confidence: .safe
    )
    static let fullDiskAccess = TestData.grant("kTCCServiceSystemPolicyAllFiles", client: grantry)
    static let automation = TestData.grant(PermissionCatalog.automationServiceID, client: grantry)
    static let plan = SelfUninstallPlan(files: [app, data, preferences], grants: [fullDiskAccess, automation])

    static func entry(_ subject: SelfUninstallReport.Subject, _ result: RemovalReport.Result) -> SelfUninstallReport.Entry {
        .init(subject: subject, result: result)
    }

    /// Passwortabfrage abgebrochen: Dienste und Festplattenvollzugriff erledigt, Daten und Einstellungen im Papierkorb,
    /// Grantry selbst nicht; Automation deswegen ausgelassen.
    static let cancelledTrash = SelfUninstallReport(entries: [
        entry(.helper, .done),
        entry(.loginItem, .done),
        entry(.grant(fullDiskAccess), .done),
        entry(.file(app), .failed("Abgebrochen (z. B. Passwortabfrage)")),
        entry(.file(data), .done),
        entry(.file(preferences), .done),
        entry(.grant(automation), .skipped(SelfUninstaller.blockedReason)),
    ], automationDenied: false, blockedBy: .file(app))
}

@Suite("Fortschritt „Grantry deinstallieren …“")
struct SelfUninstallProgressTests {
    private typealias State = SelfUninstallProgress.StepState

    @Test func stepsFollowThePlan() {
        #expect(SelfUninstallProgress(plan: Fixture.plan).steps == [.finderAccess, .services, .permissions, .trash, .finderAutomation])
        let grantsOnly = SelfUninstallPlan(files: [], grants: [Fixture.fullDiskAccess])
        #expect(SelfUninstallProgress(plan: grantsOnly).steps == [.services, .permissions])
    }

    /// Laufende, erledigte und noch ausstehende Schritte sind unterscheidbar.
    @Test func eventsMoveStepsFromPendingOverRunningToDone() {
        var progress = SelfUninstallProgress(plan: Fixture.plan)
        #expect(progress.steps.allSatisfy { progress.state(of: $0) == .pending })
        progress.apply(.started(.finderAccess))
        #expect(progress.state(of: .finderAccess) == .running)
        progress.apply(.finished(.finderAccess, []))
        progress.apply(.started(.services))
        #expect(progress.state(of: .finderAccess) == .done)
        #expect(progress.state(of: .services) == .running)
        #expect(progress.runningStep == .services)
        progress.apply(.finished(.services, [Fixture.entry(.helper, .skipped(SelfUninstaller.notRegisteredReason))]))
        #expect(progress.runningStep == nil)
        #expect(progress.state(of: .services) == .skipped)
        #expect(progress.state(of: .trash) == .pending)
        #expect(!progress.isFinished)
    }

    @Test func completionDerivesEveryStepFromTheReport() {
        var progress = SelfUninstallProgress(plan: Fixture.plan)
        progress.apply(.started(.trash))
        progress.complete(with: Fixture.cancelledTrash)
        #expect(progress.isFinished)
        #expect(progress.runningStep == nil)
        #expect(progress.state(of: .services) == .done)
        #expect(progress.state(of: .permissions) == .done)
        #expect(progress.state(of: .trash) == .partial)
        #expect(progress.state(of: .finderAutomation) == .blocked)
    }

    @Test func failedFinderAccessBlocksEverythingElse() {
        var progress = SelfUninstallProgress(plan: Fixture.plan)
        let skipped = [SelfUninstallReport.Subject.helper, .loginItem, .grant(Fixture.fullDiskAccess), .file(Fixture.app),
                       .file(Fixture.data), .file(Fixture.preferences), .grant(Fixture.automation)]
            .map { Fixture.entry($0, .skipped(RemovalExecutor.automationDeniedReason)) }
        progress.complete(with: SelfUninstallReport(entries: skipped, automationDenied: true))
        #expect(progress.state(of: .finderAccess) == .failed)
        #expect(progress.steps.dropFirst().allSatisfy { progress.state(of: $0) == .blocked })
        #expect(progress.retryPlan == Fixture.plan)
    }

    @Test func stateOfResults() {
        let blocked = RemovalReport.Result.skipped(SelfUninstaller.blockedReason)
        let notRegistered = RemovalReport.Result.skipped(SelfUninstaller.notRegisteredReason)
        #expect(SelfUninstallProgress.state(of: [.done, .doneWithWarning("neu angelegt")]) == .done)
        #expect(SelfUninstallProgress.state(of: [.done, notRegistered]) == .done)
        #expect(SelfUninstallProgress.state(of: [notRegistered]) == .skipped)
        #expect(SelfUninstallProgress.state(of: [.failed("x"), blocked]) == .failed)
        #expect(SelfUninstallProgress.state(of: [.done, .failed("x")]) == .partial)
        #expect(SelfUninstallProgress.state(of: [.done, blocked]) == .partial)
        #expect(SelfUninstallProgress.state(of: [blocked, blocked]) == .blocked)
        #expect(SelfUninstallProgress.state(of: [.skipped(RemovalExecutor.automationDeniedReason)]) == .blocked)
    }

    // MARK: - Wiederholung

    /// Ein übersprungener Gegenstand (nicht angemeldet, ausgelassen, ohne Finder-Freigabe) überschreibt nie einen
    /// früheren Erfolg; ein neues Ergebnis, das ihn tatsächlich ausgeführt hat, schon.
    @Test(arguments: [SelfUninstaller.notRegisteredReason, SelfUninstaller.blockedReason, RemovalExecutor.automationDeniedReason])
    func skippedNeverOverridesEarlierSuccess(reason: String) {
        let merged = SelfUninstallReport.merge(
            [Fixture.entry(.helper, .done), Fixture.entry(.file(Fixture.app), .failed("x"))],
            [Fixture.entry(.helper, .skipped(reason)), Fixture.entry(.file(Fixture.app), .skipped(reason))]
        )
        #expect(merged == [Fixture.entry(.helper, .done), Fixture.entry(.file(Fixture.app), .skipped(reason))])
        #expect(SelfUninstallReport.merge([Fixture.entry(.helper, .done)], [Fixture.entry(.helper, .failed("y"))])
            == [Fixture.entry(.helper, .failed("y"))])
    }

    /// Die Wiederholung gilt nur für das Offene des bestätigten Plans – Erledigtes fällt heraus, nichts kommt hinzu.
    @Test func retryPlanKeepsOnlyWhatIsStillOpen() throws {
        var progress = SelfUninstallProgress(plan: Fixture.plan)
        #expect(progress.retryPlan == nil)
        progress.complete(with: Fixture.cancelledTrash)
        let retry = try #require(progress.retryPlan)
        // Dateien gleicht jeder Versuch frisch ab – alle des bestätigten Plans; erledigte Berechtigungen fallen heraus.
        #expect(retry.files == Fixture.plan.files)
        #expect(retry.trashesFiles)
        #expect(retry.grants == [Fixture.automation])
    }

    @Test func noRetryOnceGrantryIsRemoved() {
        var progress = SelfUninstallProgress(plan: Fixture.plan)
        progress.complete(with: SelfUninstallReport(entries: [Fixture.entry(.file(Fixture.app), .done)], automationDenied: false))
        #expect(progress.retryPlan == nil)
        #expect(progress.retrying() == nil)
    }

    /// Der zweite Versuch zeigt Erledigtes weiter als erledigt; sein Bericht umfasst beide Versuche – auch die schon im
    /// ersten Versuch entsorgten Einstellungen zählen fürs Leeren beim Beenden.
    @Test func retryCarriesOverWhatTheFirstAttemptDid() throws {
        var first = SelfUninstallProgress(plan: Fixture.plan)
        first.complete(with: Fixture.cancelledTrash)
        var (second, plan) = try #require(first.retrying())
        #expect(second.attempt == 2)
        #expect(second.confirmedPlan == Fixture.plan)
        #expect(plan.files == Fixture.plan.files)
        #expect(second.state(of: .permissions) == .done)
        #expect(second.state(of: .trash) == .pending)

        // Der Dienst ist seit dem ersten Versuch abgemeldet – das bleibt so stehen.
        second.apply(.finished(.services, [Fixture.entry(.helper, .skipped(SelfUninstaller.notRegisteredReason))]))
        #expect(second.state(of: .services) == .done)

        second.complete(with: SelfUninstallReport(entries: [
            Fixture.entry(.helper, .skipped(SelfUninstaller.notRegisteredReason)),
            Fixture.entry(.loginItem, .skipped(SelfUninstaller.notRegisteredReason)),
            Fixture.entry(.file(Fixture.app), .done),
            Fixture.entry(.file(Fixture.data), .done),
            Fixture.entry(.file(Fixture.preferences), .done),
            Fixture.entry(.grant(Fixture.automation), .done),
        ], automationDenied: false))
        let report = try #require(second.report)
        #expect(report.appRemoved)
        #expect(report.clearsPreferences)
        #expect(report.entries.first { $0.subject == .helper }?.result == .done)
        #expect(Set(report.entries.map(\.subject)).count == 7)
        #expect(second.steps.allSatisfy { second.state(of: $0) == .done })
    }
}

/// Vollständigkeit als Eigenschaft über alle Kombinationen von Ergebnissen (#143): `isComplete` genau dann, wenn jeder
/// Gegenstand erledigt bzw. (Dienst) nicht nötig ist – und Titel, Ton, Wiederholung, Fortschritt und Meldung folgen.
@Suite("Vollständigkeit „Grantry deinstallieren …“")
struct SelfUninstallCompletenessTests {
    private static let subjects: [SelfUninstallReport.Subject] = [
        .helper, .loginItem, .grant(Fixture.fullDiskAccess), .grant(Fixture.automation), .file(Fixture.app), .file(Fixture.data),
    ]
    private static let plan = SelfUninstallPlan(files: [Fixture.app, Fixture.data], grants: [Fixture.fullDiskAccess, Fixture.automation])

    private static func results(for subject: SelfUninstallReport.Subject) -> [RemovalReport.Result] {
        var results: [RemovalReport.Result] = [
            .done, .failed("x"), .skipped(SelfUninstaller.blockedReason), .skipped(RemovalExecutor.automationDeniedReason),
        ]
        switch subject {
        case .helper, .loginItem: results.append(.skipped(SelfUninstaller.notRegisteredReason))
        case .file: results.append(.doneWithWarning(RemovalExecutor.recreatedWarning))
        case .grant: break
        }
        return results
    }

    private static func isSettled(_ entry: SelfUninstallReport.Entry) -> Bool {
        entry.result.isDone || (entry.result == .skipped(SelfUninstaller.notRegisteredReason)
            && [.helper, .loginItem].contains(entry.subject))
    }

    /// Alle Kombinationen (5·5·4·4·5·5 = 10 000).
    private static var combinations: [[SelfUninstallReport.Entry]] {
        subjects.reduce([[]]) { partial, subject in
            partial.flatMap { prefix in results(for: subject).map { prefix + [.init(subject: subject, result: $0)] } }
        }
    }

    @Test func completenessFollowsEverySubject() {
        var completeCount = 0
        for entries in Self.combinations {
            let report = SelfUninstallReport(entries: entries, automationDenied: false)
            let expected = entries.allSatisfy(Self.isSettled)
            #expect(report.isComplete == expected)
            guard report.isComplete == expected else { return }
            if expected { completeCount += 1 }

            var progress = SelfUninstallProgress(plan: Self.plan)
            progress.complete(with: report)
            let presentation = SelfUninstallProgressPresentation(progress, home: "/Users/test")
            let outcome = presentation.outcome
            let consistent = (presentation.title == SelfUninstallProgressTexts.finishedTitle) == expected
                && (!expected || !presentation.offersRetry)
                && (outcome?.tone == .positive ? expected : true)
                && (outcome?.text.contains(SelfUninstallTexts.removed) == expected)
                && (!expected || progress.steps.allSatisfy { [.done, .skipped].contains(progress.state(of: $0)) })
                && (expected || !report.appRemoved || Self.namesEveryOpenCategory(report, outcome?.text ?? ""))
            #expect(consistent, "\(entries.map(\.result))")
            guard consistent else { return }
        }
        // Vollständig: je Dienst erledigt oder nicht angemeldet, je Berechtigung erledigt, je Datei erledigt (ggf. mit Warnung).
        #expect(completeCount == 2 * 2 * 1 * 1 * 2 * 2)
    }

    /// Bei entsorgtem Bundle nennt die Meldung jede Kategorie offener Reste mit ihrem manuellen Weg.
    private static func namesEveryOpenCategory(_ report: SelfUninstallReport, _ text: String) -> Bool {
        (report.servicesStillRegistered.isEmpty || text.contains("Anmeldeobjekte & Erweiterungen"))
            && (report.grantsLeftBehind.isEmpty || text.contains("tccutil reset"))
            && (report.filesLeftBehind.isEmpty || text.contains("im Finder selbst in den Papierkorb"))
    }
}

@MainActor
@Suite("Ablauf „Grantry deinstallieren …“ – Fortschritt und Wiederholung")
struct SelfUninstallFlowProgressTests {
    /// Während des Ablaufs spiegelt `progress` den laufenden Schritt; danach liegt der Bericht vor.
    @Test(.timeLimit(.minutes(1))) func progressFollowsTheRunningUninstall() async throws {
        let gate = Gate()
        let flow = SelfUninstallFlow(helperActivity: HelperActivityLock()) { _, progress in
            await progress(.started(.services))
            try? await gate.wait()
            await progress(.finished(.services, [.init(subject: .helper, result: .done)]))
            return Fixture.cancelledTrash
        }
        let running = Task { await flow.run(Fixture.plan) }
        while flow.progress?.runningStep != .services { await Task.yield() }
        #expect(flow.isRunning)
        flow.dismiss()
        #expect(flow.progress != nil, "Ein laufender Ablauf bleibt sichtbar")
        #expect(!flow.canRetry)

        gate.open()
        _ = await running.value
        #expect(flow.progress?.isFinished == true)
        #expect(flow.canRetry)
        flow.dismiss()
        #expect(flow.progress == nil)
    }

    /// „Erneut versuchen“ führt nur das Offene des bestätigten Plans aus.
    @Test func retryRunsOnlyTheRemainingPlan() async throws {
        let plans = Mutex<[SelfUninstallPlan]>([])
        let reports = Mutex([
            Fixture.cancelledTrash,
            SelfUninstallReport(entries: [
                Fixture.entry(.file(Fixture.app), .done), Fixture.entry(.grant(Fixture.automation), .done),
            ], automationDenied: false),
        ])
        let flow = SelfUninstallFlow(helperActivity: HelperActivityLock(), uninstall: { plan, _ in
            plans.withLock { $0.append(plan) }
            return reports.withLock { $0.removeFirst() }
        }, isInTrash: { _ in true })
        #expect(await flow.retry() == nil, "Ohne vorherigen Ablauf gibt es nichts zu wiederholen")
        _ = await flow.run(Fixture.plan)
        let report = try #require(await flow.retry())
        #expect(plans.withLock { $0 } == [
            Fixture.plan, SelfUninstallPlan(files: Fixture.plan.files, grants: [Fixture.automation]),
        ])
        #expect(report.appRemoved)
        #expect(flow.clearsPreferences)
        #expect(flow.progress?.attempt == 2)
        #expect(!flow.canRetry)
    }

    /// Auch die Wiederholung ist Helper-Wartung: Läuft eine Aktion, geschieht nichts, und der Bericht bleibt sichtbar.
    @Test func retryIsRefusedWhileAnActionRuns() async throws {
        let lock = HelperActivityLock()
        let calls = Mutex(0)
        let flow = SelfUninstallFlow(helperActivity: lock) { _, _ in
            calls.withLock { $0 += 1 }
            return Fixture.cancelledTrash
        }
        _ = await flow.run(Fixture.plan)
        #expect(lock.begin(.action))
        #expect(!flow.canRetry)
        #expect(await flow.retry() == nil)
        #expect(flow.progress?.attempt == 1)
        #expect(flow.progress?.isFinished == true)
        lock.end(.action)
        #expect(calls.withLock { $0 } == 1)
    }
}

// Nutzt die nur in Debug-Builds vorhandenen Preview-Daten.
#if DEBUG
@Suite("Anzeige des Fortschritts „Grantry deinstallieren …“")
struct SelfUninstallProgressPresentationTests {
    @Test func runningStepShowsItsHintAndNoCancel() {
        let presentation = SelfUninstallProgressPresentation(SelfUninstallPreviewData.trashing, home: "/Users/test")
        #expect(presentation.isRunning)
        #expect(presentation.title == SelfUninstallProgressTexts.runningTitle)
        #expect(presentation.runningHint == SelfUninstallProgressTexts.hint(for: .trash))
        #expect(presentation.runningHint?.contains("Passwort") == true)
        #expect(presentation.notes == [SelfUninstallProgressTexts.noCancelNote])
        #expect(presentation.outcome == nil)
        #expect(!presentation.offersRetry)
        #expect(presentation.announcement == "In den Papierkorb legen: Läuft …")
        let trash = presentation.rows.first { $0.step == .trash }
        #expect(trash?.systemImage == nil)
        #expect(trash?.accessibilityLabel == "In den Papierkorb legen: Läuft …")
        #expect(presentation.rows.map(\.statusText) == ["Erledigt", "Erledigt", "Erledigt", "Läuft …", "Ausstehend"])
    }

    /// Jeder Zustand hat eigenen Text und eigenes Symbol – nicht nur eine Farbe.
    @Test func everyStateHasItsOwnTextAndSymbol() {
        let states: [SelfUninstallProgress.StepState] = [.pending, .done, .skipped, .partial, .failed, .blocked]
        #expect(Set(states.map(SelfUninstallProgressPresentation.statusText)).count == states.count)
        let symbols = states.map { SelfUninstallProgressPresentation.row(.trash, state: $0).systemImage }
        #expect(Set(symbols).count == states.count)
        #expect(!symbols.contains(nil))
        #expect(SelfUninstallProgressPresentation.row(.trash, state: .running).systemImage == nil)
    }

    @Test func cancelledPasswordOffersRetryWithNextSteps() {
        let presentation = SelfUninstallProgressPresentation(SelfUninstallPreviewData.passwordCancelled, home: "/Users/test")
        #expect(!presentation.isRunning)
        #expect(presentation.title == SelfUninstallProgressTexts.unfinishedTitle)
        #expect(presentation.offersRetry)
        #expect(presentation.notes == [SelfUninstallProgressTexts.retryNote])
        #expect(!presentation.quitsApp)
        #expect(presentation.outcome?.tone == .critical)
        #expect(presentation.announcement == presentation.outcome?.text)
        #expect(presentation.rows.first { $0.step == .trash }?.statusText == "Teilweise erledigt")
        #expect(presentation.rows.first { $0.step == .finderAutomation }?.statusText == "Nicht ausgeführt")
    }

    @Test func helperFailureNamesTheBlockedSteps() {
        let presentation = SelfUninstallProgressPresentation(SelfUninstallPreviewData.helperFailed, home: "/Users/test")
        #expect(presentation.rows.map(\.state) == [.done, .failed, .blocked, .blocked, .blocked])
        #expect(presentation.outcome?.text.contains("Hintergrunddienst") == true)
        #expect(presentation.offersRetry)
    }

    @Test func removedGrantryOnlyQuits() {
        let presentation = SelfUninstallProgressPresentation(SelfUninstallPreviewData.removed, home: "/Users/test")
        #expect(presentation.quitsApp)
        #expect(!presentation.offersRetry)
        #expect(presentation.notes.isEmpty)
        #expect(presentation.title == SelfUninstallProgressTexts.finishedTitle)
    }
}
#endif
