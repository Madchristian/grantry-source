import Foundation

/// Ein neuer Eintrag einer Beobachtung, der im **aktuellen** Stand noch existiert und sich entfernen ließe (#127).
public struct ObservationCleanupCandidate: Identifiable, Hashable, Sendable {
    public enum Subject: Hashable, Sendable {
        case grant(PermissionGrant)
        case autostartItem(AutostartItem)
        case installedApp(InstalledApp)
    }

    /// Der Eintrag, wie ihn der aktuelle Scan kennt.
    public let subject: Subject
    public let verdict: ObservationAttribution.Verdict
    /// Warum sich der Eintrag nicht entfernen lässt (`ActionPolicy`, `RemovalRoute`); `nil`, wenn er wählbar ist.
    public let unavailableReason: String?

    public var id: String {
        switch subject {
        case .grant(let grant): grant.id
        case .autostartItem(let item): item.id
        case .installedApp(let app): app.id
        }
    }

    /// Vorausgewählt: wahrscheinlich zugehörig und entfernbar.
    public var isPreselected: Bool { verdict.isLikely && unavailableReason == nil }
}

/// Was aus einer Beobachtung heute noch entfernt werden kann: jeder damals neue Eintrag, der im aktuellen Snapshot noch
/// derselbe ist (#127, Abgleich wie #100) – Berechtigung mit gleicher ID, Autostart-Eintrag mit gleicher ID, gleichem
/// Programm und derselben Plist (`isSameAutostartItem`), App am selben Ort mit gleicher Bundle-ID und gleichem Team. Was
/// fehlt oder inzwischen ein anderer Eintrag ist, wird nicht angeboten.
public struct ObservationCleanupOffer: Hashable, Sendable {
    public let candidates: [ObservationCleanupCandidate]
    /// Neue Einträge, die nicht mehr (oder nicht mehr als derselbe) vorhanden sind.
    public let goneCount: Int

    public init(
        balance: ObservationBalance, attribution: ObservationAttribution, current: Snapshot,
        policy: ActionPolicy = ActionPolicy()
    ) {
        let grants = current.grants.firstByID()
        let items = current.autostartItems.firstByID()
        let apps = current.installedApps.firstByID()
        var candidates: [ObservationCleanupCandidate] = []
        var gone = 0
        for event in balance.added {
            let verdict = attribution.verdict(for: event.subject)
            let candidate: ObservationCleanupCandidate? = switch event.subject {
            case .grant(let grant):
                grants[grant.id].map { current in
                    ObservationCleanupCandidate(subject: .grant(current), verdict: verdict,
                                                unavailableReason: policy.availability(for: current).reason)
                }
            case .autostartItem(let item):
                items[item.id].flatMap { current in
                    guard Self.isSameAutostartItem(item, current) else { return nil }
                    return ObservationCleanupCandidate(subject: .autostartItem(current), verdict: verdict,
                                                       unavailableReason: policy.availability(for: current).reason)
                }
            case .installedApp(let app):
                apps[app.id].flatMap { current in
                    guard Self.isSameApp(app, current) else { return nil }
                    return ObservationCleanupCandidate(subject: .installedApp(current), verdict: verdict,
                                                       unavailableReason: RemovalRoute.route(for: current).reason)
                }
            default:
                nil
            }
            if let candidate { candidates.append(candidate) } else if Self.isRemovable(event.subject) { gone += 1 }
        }
        self.candidates = candidates
        goneCount = gone
    }

    public var initialSelection: RemovalSelection {
        RemovalSelection(preselected: candidates.filter(\.isPreselected).map(\.id))
    }

    /// Gleiche Bundle-ID und – wenn beide bekannt – gleiche Team-ID: Ein Austausch am selben Ort ist eine andere App.
    static func isSameApp(_ recorded: InstalledApp, _ current: InstalledApp) -> Bool {
        guard recorded.bundleID?.lowercased() == current.bundleID?.lowercased() else { return false }
        guard let recordedTeam = recorded.referenceTeamID, let currentTeam = current.referenceTeamID else { return true }
        return recordedTeam == currentTeam
    }

    /// Gleiches Programm, gleiche Plist (Pfad) und – wenn beide bekannt – derselbe Inhaltsfingerabdruck: Die ID
    /// (Art, Domain, Label) allein reicht nicht, denn eine andere Plist kann dasselbe Label tragen und denselben
    /// Interpreter starten (#156). Eine seither umgeschriebene Plist gilt als veränderter, nicht mehr der beobachtete
    /// Eintrag. Ohne Fingerabdruck (ältere Snapshots, andere Quellen) genügen Pfad, Programm und – wenn beide bekannt –
    /// die Argumente (#137).
    static func isSameAutostartItem(_ recorded: AutostartItem, _ current: AutostartItem) -> Bool {
        guard recorded.program == current.program, recorded.plistPath == current.plistPath,
              !recorded.argumentsDiffer(from: current) else { return false }
        guard let recordedFingerprint = recorded.plistFingerprint, let currentFingerprint = current.plistFingerprint else {
            return true
        }
        return recordedFingerprint.matches(currentFingerprint)
    }

    /// Arten, die das Aufräumen kennt; neue Gegenstände anderer Quellen zählen nicht als „nicht mehr vorhanden“.
    private static func isRemovable(_ subject: ChangeSubject) -> Bool {
        switch subject {
        case .grant, .autostartItem, .installedApp: true
        default: false
        }
    }
}

extension ActionAvailability {
    /// Grund, warum nur Lesen möglich ist; `nil` bei `.available`.
    var reason: String? {
        if case .readOnly(let reason) = self { reason.description } else { nil }
    }
}

/// Aufräumen aus einer Beobachtung (#127) – ausschließlich aus vorhandenen Aktionen zusammengesetzt: Berechtigungen
/// zurücksetzen, Autostart-Einträge entfernen (mit Beleg) und Apps über den Entfernen-Ablauf. Von einer App geht nur das
/// Bundle selbst mit: Die Beobachtung kennt keine Dateien, Reste wie `Application Support` können schon vorher bestanden
/// haben (Nutzerdaten). Die wählt der Nutzer einzeln über „App entfernen …“ (Entfernen-Blatt).
public struct ObservationCleanupPlan: Hashable, Sendable, Identifiable {
    public let observationID: UUID
    /// Einzeln zurückzusetzen – vor dem Entfernen der Apps, denn `tccutil` braucht die installierte App.
    public let grants: [PermissionGrant]
    /// Einzeln zu entfernen (mit Wiederherstellungsbeleg).
    public let autostartItems: [AutostartItem]
    /// Je App ein Plan des Entfernen-Ablaufs.
    public let appRemovals: [RemovalPlan]

    public var id: String { Self.id(for: observationID) }

    /// `ActionRunner.runningRecordID` während des Aufräumens aus der Beobachtung `observationID`.
    public static func id(for observationID: UUID) -> String { "observation|\(observationID.uuidString)" }
    public var isEmpty: Bool { grants.isEmpty && autostartItems.isEmpty && appRemovals.isEmpty }
}

public enum ObservationCleanupPlanning {
    /// Plan aus Auswahl und Reste-Suche (`leftovers` je `InstalledApp.id`; Apps ohne Suchergebnis entfallen, denn das
    /// App-Bundle selbst ist ein Kandidat der Suche). Für gewählte Apps gehen nur das App-Bundle sowie die gewählten
    /// Berechtigungen und Autostart-Einträge der App in den App-Plan (`RemovalPlanning`); alles Übrige wird einzeln
    /// ausgeführt. Weitere Reste bleiben liegen (siehe `ObservationCleanupPlan`).
    public static func plan(
        observationID: UUID, offer: ObservationCleanupOffer, selection: RemovalSelection,
        leftovers: [String: LeftoverScanResult], snapshot: Snapshot, policy: ActionPolicy = ActionPolicy()
    ) -> ObservationCleanupPlan {
        let selected = offer.candidates.filter { selection.contains($0.id) && $0.unavailableReason == nil }
        var appRemovals: [RemovalPlan] = []
        for case .installedApp(let app) in selected.map(\.subject) {
            guard let result = leftovers[app.id] else { continue }
            let appSelection = selection.selected.union([app.path])
            appRemovals.append(RemovalPlanning.plan(
                for: app, leftovers: result, snapshot: snapshot, selection: appSelection, policy: policy
            ))
        }
        let handledByApps = Set(appRemovals.flatMap { $0.grants.map(\.id) + $0.autostartItems.map(\.id) })
        var grants: [PermissionGrant] = []
        var items: [AutostartItem] = []
        for candidate in selected where !handledByApps.contains(candidate.id) {
            switch candidate.subject {
            case .grant(let grant): grants.append(grant)
            case .autostartItem(let item): items.append(item)
            case .installedApp: break
            }
        }
        return ObservationCleanupPlan(
            observationID: observationID, grants: grants, autostartItems: items, appRemovals: appRemovals
        )
    }
}

/// Führt einen `ObservationCleanupPlan` über die vorhandenen Aktionen aus (`ActionPerforming`): erst Berechtigungen,
/// dann Autostart-Einträge, dann Apps. Jede Einzelaktion prüft ihre Wirkung wie gewohnt; Fehler halten die übrigen nicht
/// auf. Wird der Task abgebrochen, beginnt kein weiterer Schritt – der Rest steht als „abgebrochen“ im Bericht.
struct ObservationCleanupExecutor: Sendable {
    let performer: any ActionPerforming

    /// - Parameter onEntry: erhält jeden Eintrag, sobald er feststeht – so bleibt Erledigtes auch dann bekannt, wenn das
    ///   Warten auf das Ende verworfen wird (`ActionRunner.abandonRunningAction()`).
    func run(
        _ plan: ObservationCleanupPlan, onEntry: @escaping @Sendable (RemovalReport.Entry) -> Void = { _ in },
        onExecuted: @escaping @Sendable (RemovalReport) async -> Void
    ) async -> RemovalReport {
        var entries: [RemovalReport.Entry] = []
        func append(_ new: [RemovalReport.Entry]) {
            entries += new
            new.forEach(onEntry)
        }
        for grant in plan.grants {
            append([await step(.grant(grant)) { await performer.reset(grant) }])
        }
        for item in plan.autostartItems {
            append([await step(.autostartItem(item)) { await performer.remove(item) }])
        }
        for removal in plan.appRemovals {
            if Task.isCancelled {
                append(RemovalReport.skipping(removal, reason: RemovalExecutor.abortedReason).entries)
            } else {
                append(await performer.performRemoval(removal, onExecuted: onExecuted).entries)
            }
        }
        return RemovalReport(entries: entries)
    }

    private func step(
        _ subject: RemovalReport.Subject, _ action: () async -> ActionOutcome
    ) async -> RemovalReport.Entry {
        guard !Task.isCancelled else {
            return RemovalReport.Entry(subject: subject, result: .skipped(RemovalExecutor.abortedReason))
        }
        return RemovalReport.Entry(subject: subject, result: RemovalReport.Result(await action()))
    }
}

extension RemovalReport.Result {
    /// Ergebnis einer Einzelaktion im Bericht: unbestätigt wird zur Warnung.
    init(_ outcome: ActionOutcome) {
        switch outcome {
        case .done: self = .done
        case .doneButUnverified(let message, _): self = .doneWithWarning(message)
        case .failed(let message): self = .failed(message)
        }
    }
}
