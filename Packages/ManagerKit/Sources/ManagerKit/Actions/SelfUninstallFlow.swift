import Foundation
import Observation

/// Ablauf „Grantry deinstallieren …“ für die Oberfläche (#115): führt den `SelfUninstaller` als Helper-Wartung aus
/// (`HelperActivityLock` – der Helper wird abgemeldet, Aktionen und Neuinstallation sind solange gesperrt) und hält den
/// laufenden Vorgang fest, damit das reguläre Beenden ihn abwartet (`drain()`, #156): Ein schon gesendeter
/// Finder-Auftrag liefe sonst weiter, während Automation-Reset, Bericht und das Leeren der Einstellungen ausblieben.
///
/// `progress` spiegelt Schritte, Bericht und Wiederholung des bestätigten Plans (#143). Einen Abbruch bietet der Ablauf
/// bewusst nicht an: An Finder oder `SMAppService` gesendete Aufträge laufen weiter.
@MainActor
@Observable
public final class SelfUninstallFlow {
    /// Führt einen Plan aus und meldet den Fortschritt; in der App `SelfUninstaller.run(_:progress:)`.
    public typealias Uninstall = @Sendable (SelfUninstallPlan, @escaping SelfUninstallProgressHandler) async -> SelfUninstallReport

    @ObservationIgnored private let helperActivity: HelperActivityLock
    @ObservationIgnored private let uninstall: Uninstall
    /// Ob eine Datei als Original nachweislich im Papierkorb liegt – vor dem Leeren der Einstellungen (#143).
    @ObservationIgnored private let isInTrash: @Sendable (LeftoverCandidate) -> Bool
    /// Gibt festgehaltene Originale frei (`TrackedFileLocator.release`) – bei neuem Ablauf und beim Schließen.
    @ObservationIgnored private let releaseTracking: @Sendable () -> Void
    private var running: Task<SelfUninstallReport?, Never>?
    /// Fortschritt des bestätigten Plans über alle Versuche; `nil`, bis ein Ablauf beginnt bzw. nach `dismiss()`.
    public private(set) var progress: SelfUninstallProgress?
    /// Bericht des letzten abgeschlossenen Ablaufs, samt dem Erledigten früherer Versuche.
    public private(set) var lastReport: SelfUninstallReport?

    public init(
        helperActivity: HelperActivityLock,
        uninstall: @escaping Uninstall = { await SelfUninstaller().run($0, progress: $1) },
        isInTrash: @escaping @Sendable (LeftoverCandidate) -> Bool = { FinderTrash().settledOutcome(of: $0) != nil },
        releaseTracking: @escaping @Sendable () -> Void = {}
    ) {
        self.helperActivity = helperActivity
        self.uninstall = uninstall
        self.isInTrash = isInTrash
        self.releaseTracking = releaseTracking
    }

    /// In der App: Ein `TrackedFileLocator` je Ablauf hält die Originale über Wiederholungen bis zum Beenden fest, damit
    /// Nachweis und Beenden-Prüfung auch ohne Festplattenvollzugriff gelingen (#143).
    public static func live(helperActivity: HelperActivityLock) -> SelfUninstallFlow {
        let locator = TrackedFileLocator()
        let trash = FinderTrash(tracking: locator)
        return SelfUninstallFlow(
            helperActivity: helperActivity, uninstall: { await SelfUninstaller(trash: trash).run($0, progress: $1) },
            isInTrash: { trash.settledOutcome(of: $0) != nil }, releaseTracking: locator.release
        )
    }

    public var isRunning: Bool { running != nil }

    /// Ob „Erneut versuchen“ möglich ist: Der letzte Versuch ist fertig, Grantry nicht entfernt und nichts anderes läuft.
    public var canRetry: Bool { running == nil && helperActivity.isIdle && progress?.retryPlan != nil }

    /// Führt den bestätigten Plan aus; `nil`, ohne etwas zu tun, wenn schon ein Ablauf, eine Aktion oder eine
    /// Helper-Wartung läuft (die Bestätigung im Blatt ist dann gesperrt).
    public func run(_ plan: SelfUninstallPlan) async -> SelfUninstallReport? {
        guard running == nil, helperActivity.isIdle else { return nil }
        releaseTracking()
        return await perform(plan, progress: SelfUninstallProgress(plan: plan))
    }

    /// Wiederholt die noch offenen Teile des bestätigten Plans (`SelfUninstallProgress.retryPlan`) – nie mehr, und auf
    /// dem tatsächlichen Zustand: Erledigtes bleibt aus, Dienste prüft der `SelfUninstaller` frisch. `nil`, wenn keine
    /// Wiederholung möglich ist oder etwas anderes läuft.
    public func retry() async -> SelfUninstallReport? {
        guard running == nil, let next = progress?.retrying() else { return nil }
        return await perform(next.plan, progress: next.progress)
    }

    /// Schließt die Anzeige des abgeschlossenen Ablaufs; während er läuft, bleibt sie.
    public func dismiss() {
        guard running == nil else { return }
        progress = nil
        releaseTracking()
    }

    /// Wartet, bis ein laufender Ablauf abgeschlossen ist (vor dem Beenden); bricht ihn nicht ab.
    public func drain() async {
        _ = await running?.value
    }

    /// Ob das Beenden die Einstellungen leeren soll (`SelfUninstaller.clearPreferences`, siehe
    /// `SelfUninstallReport.clearsPreferences`) – frisch geprüft: Nur wenn ihre Sicherung weiterhin als Original im
    /// Papierkorb liegt; wurde sie zurückgelegt oder entfernt, bleiben die Einstellungen (#143).
    public var clearsPreferences: Bool {
        guard let report = lastReport, report.clearsPreferences, let file = report.removedPreferencesFile else { return false }
        return isInTrash(file)
    }

    private func perform(_ plan: SelfUninstallPlan, progress attempt: SelfUninstallProgress) async -> SelfUninstallReport? {
        guard running == nil, helperActivity.isIdle else { return nil }
        let previous = progress
        progress = attempt
        let helperActivity = helperActivity, uninstall = uninstall
        let report: @Sendable (SelfUninstallEvent) async -> Void = { [weak self] event in await self?.apply(event) }
        let task = Task { await helperActivity.perform(.helperMaintenance) { await uninstall(plan, report) } }
        running = task
        defer { running = nil }
        guard let attemptReport = await task.value else {
            progress = previous
            return nil
        }
        self.progress?.complete(with: attemptReport)
        let complete = self.progress?.report ?? attemptReport
        lastReport = complete
        return complete
    }

    private func apply(_ event: SelfUninstallEvent) {
        progress?.apply(event)
    }
}
