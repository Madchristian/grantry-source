import ManagerKit
import Observation

/// Zustand des Entfernen-Blatts (Spec v3 §3): Reste-Suche auf Abruf, Auswahl, ob die App läuft, und der Plan aus dem
/// **unveränderten** Suchergebnis. Snapshot und Verknüpfungen werden beim Öffnen festgehalten, damit Anzeige und Plan
/// dieselben Berechtigungen und Autostart-Einträge meinen; was sich bis zum Ausführen ändert (neue Installationen,
/// weitere Apps desselben Teams), gleicht der `RemovalExecutor` vor dem Eingriff mit einem frischen Scan ab (#97, #100).
@MainActor
@Observable
final class RemovalModel {
    let request: RemovalRequest
    let route: RemovalRoute
    let search = CancellableSearch()
    private(set) var review: RemovalReview?
    var selection = RemovalSelection(preselected: [])
    private(set) var isAppRunning = false
    /// Die App hat die Bitte zum Beenden abgelehnt (oder lief nicht mehr).
    private(set) var quitFailed = false

    @ObservationIgnored private let snapshot: Snapshot?
    @ObservationIgnored private let scanner: LeftoverScanner
    @ObservationIgnored private let runningApps: WorkspaceRunningApplications
    /// Unverändertes Ergebnis der Suche – Quelle des Plans (Kandidaten werden nie neu erzeugt).
    @ObservationIgnored private var leftovers: LeftoverScanResult?

    init(request: RemovalRequest, snapshot: Snapshot?, scanner: LeftoverScanner, runningApps: WorkspaceRunningApplications) {
        self.request = request
        self.snapshot = snapshot
        self.scanner = scanner
        self.runningApps = runningApps
        route = RemovalRoute.route(for: request.app)
    }

    var app: InstalledApp { request.app }

    /// Grantry selbst: „Grantry deinstallieren …“ (`SelfUninstaller`) statt des `RemovalExecutor`.
    var isSelfUninstall: Bool { route == .grantryItself }

    /// Ob sich Reste suchen lassen: entfernbare App bzw. Grantry selbst und ein Snapshot (sonst ist der Abgleich mit
    /// anderen Apps offen).
    var canSearch: Bool { (route == .removable || isSelfUninstall) && snapshot != nil }

    /// Sucht die Reste (nur lesend); eine laufende Suche wird ersetzt.
    func startSearch() {
        guard canSearch, let snapshot else { return }
        let app = app, scanner = scanner, installedApps = snapshot.installedApps
        let found = AppLinks.of(app, in: snapshot)
        // Helper und Login-Item von Grantry meldet der `SelfUninstaller` über `SMAppService` ab, nicht als Autostart.
        let links = isSelfUninstall
            ? AppLinks(grants: found.grants, autostartItems: [], sharedIDs: found.sharedIDs, otherInstallations: found.otherInstallations)
            : found
        let mode = request.mode
        review = nil
        leftovers = nil
        search.start({ await scanner.scan(for: app, installedApps: installedApps) }) { [weak self] result in
            let review = RemovalReview(leftovers: result, links: links)
            var selection = review.initialSelection
            if mode == .leftovers {
                for id in [app.path] + links.grants.map(\.id) + links.autostartItems.map(\.id) {
                    selection.set(id, selected: false)
                }
            }
            self?.leftovers = result
            self?.selection = selection
            self?.review = review
        }
    }

    /// Plan aus Suchergebnis und Auswahl; `nil` vor dem Ende der Suche.
    var plan: RemovalPlan? {
        guard let leftovers, let snapshot, review != nil else { return nil }
        return RemovalPlanning.plan(for: app, leftovers: leftovers, snapshot: snapshot, selection: selection.selected)
    }

    /// Plan für „Grantry deinstallieren …“; `nil` vor dem Ende der Suche oder für andere Apps.
    var selfUninstallPlan: SelfUninstallPlan? {
        guard isSelfUninstall else { return nil }
        return plan.map(SelfUninstallPlan.init)
    }

    /// Ob die Bestätigung möglich ist: keine Vorschau, Suche fertig, keine andere Aktion läuft; zum Entfernen einer App
    /// muss sie beendet und etwas ausgewählt sein, zum Deinstallieren von Grantry das App-Bundle selbst.
    func canConfirm(actionsCanStart: Bool) -> Bool {
        guard !request.isPreview, search.phase == .finished, actionsCanStart else { return false }
        switch route {
        case .removable: return !isAppRunning && plan?.isEmpty == false
        case .grantryItself: return selfUninstallPlan?.includesApp == true
        case .homebrew, .otherGrantryCopy: return false
        }
    }

    /// Prüft im Sekundentakt, ob die App läuft – solange das Blatt offen ist (Aufruf aus `.task`).
    func watchRunningState() async {
        // Grantry läuft beim Deinstallieren naturgemäß und beendet sich danach selbst.
        guard !isSelfUninstall else { return }
        while !Task.isCancelled {
            isAppRunning = await runningApps.isRunning(app)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Bittet die App, sich zu beenden („Beenden“); ungesicherte Dokumente fragt sie selbst nach.
    func quitApp() {
        quitFailed = !runningApps.terminate(app)
    }
}
