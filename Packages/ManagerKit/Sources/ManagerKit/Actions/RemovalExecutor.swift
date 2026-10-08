import Foundation
import os

/// Führt einen `RemovalPlan` aus (Spec v3 §3 Schritt 4); der `ActionCoordinator` reiht ein und scannt danach.
///
/// 1. Homebrew-Cask oder Grantry selbst (`RemovalRoute`) → nichts tun. 2. Läuft die App → nichts tun. 3. Abgleich des
/// Plans mit dem aktuellen Stand (unten). 4. Bleiben Dateien → Automation-Freigabe für den Finder prüfen (ggf. mit
/// Rückfrage von macOS); ohne Freigabe nichts tun. 5. Berechtigungen zurücksetzen (`tccutil` braucht die installierte
/// App). 6. Autostart-Einträge entfernen (v1, mit Wiederherstellungsbeleg). 7. Die App erneut auf „läuft“ prüfen, jeden
/// Kandidaten erneut durch den `RemovalGuard` (dasselbe Objekt wie bei der Suche; Apple-Kennungen nur für die entfernte
/// App), dann alle zulässigen Dateien mit **einem** Apple Event in den Papierkorb – unmittelbar davor prüft der
/// Papierkorb jeden noch einmal mit dem Guard. Fehler einzelner Einträge halten die übrigen nicht auf.
///
/// Abbruch (`abortedBy`, Issue #102): Vor jedem Schritt – dem Abgleich, jeder Berechtigung, jedem Autostart-Eintrag und
/// dem Finder-Auftrag – prüft der Executor das Signal. Ein bereits begonnener Schritt (etwa ein am Helper hängender
/// Aufruf) läuft zu Ende, danach beginnt keiner mehr; nicht Begonnenes erscheint als `abortedReason` im Bericht,
/// Erledigtes bleibt samt Wiederherstellungsbeleg erhalten. Den Abgleichsscan kürzt der Aufrufer ab (`currentSnapshot`
/// liefert dann `nil`); ein währenddessen abgebrochener Plan gilt vollständig als abgebrochen.
///
/// Abgleich mit dem aktuellen Stand (`currentSnapshot`), bevor der Finder gefragt wird – was übersprungen wird, steht mit
/// Grund im Bericht, und ohne verbleibende Dateien gibt es keine Finder-Rückfrage:
/// - Aufräumen (`plan.app == nil`, `OrphanRecheck`): jeder begründete Fund (`orphanClaims`) und jeder verwaiste
///   Autostart-Eintrag; was inzwischen einer installierten App gehört, bleibt liegen (Review I1).
/// - Entfernen einer App (`AppRemovalRecheck`): Berechtigungen und Autostart-Einträge gegen die aktuell installierten
///   Apps (#97) und jeder Rest mit den Regeln der Suche (#100) – was inzwischen einer anderen App gehört oder nicht mehr
///   exklusiv ist (neue App desselben Teams, neue Installation derselben Bundle-ID), bleibt liegen; liegt am Ort der App
///   eine andere, bleibt alles liegen.
struct RemovalExecutor: Sendable {
    static let automationDeniedReason = "Keine Automation-Freigabe für den Finder – nichts wurde verändert."
    static let missingFinderResult = "Kein Ergebnis vom Finder"
    static let recreatedWarning = "In den Papierkorb gelegt – am Ort wurde inzwischen ein neuer Eintrag angelegt."
    static let abortedReason = "Abgebrochen – nicht mehr ausgeführt."

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "removal")

    let permissions: any PermissionResetting
    let autostart: any AutostartControlling
    let receipts: ReceiptStore
    let trash: any TrashPerforming
    let runningApps: any RunningApplicationChecking
    let removalGuard: RemovalGuard
    /// Snapshot eines frischen Scans für den Abgleich (`OrphanRecheck`, `AppRemovalRecheck`); `nil`, wenn keiner vorliegt
    /// (auch nach Abbruch).
    let currentSnapshot: @Sendable () async -> Snapshot?
    let now: @Sendable () -> Date

    static func runningReason(_ app: InstalledApp) -> String {
        "\(app.name) läuft noch – bitte zuerst beenden."
    }

    func run(_ plan: RemovalPlan, abortedBy abort: OneShotSignal = OneShotSignal()) async -> RemovalReport {
        if abort.isFired { return .skipping(plan, reason: Self.abortedReason) }
        if let app = plan.app {
            if let reason = RemovalRoute.route(for: app).reason { return .skipping(plan, reason: reason) }
            if await runningApps.isRunning(app) { return .skipping(plan, reason: Self.runningReason(app)) }
        }
        let outdated = await outdated(in: plan)
        // Ein während des Abgleichs abgebrochener Plan hat noch nichts begonnen; der abgekürzte Scan ist kein Befund.
        if abort.isFired { return .skipping(plan, reason: Self.abortedReason) }
        let files = plan.files.filter { outdated.files[$0.path] == nil }
        if !files.isEmpty {
            switch await trash.requestPermission() {
            case .granted: break
            case .denied: return .skipping(plan, reason: Self.automationDeniedReason, automationDenied: true)
            case .unavailable(let reason): return .skipping(plan, reason: reason)
            }
        }
        var entries: [RemovalReport.Entry] = []
        for grant in plan.grants {
            if let reason = outdated.grants[grant.id] {
                entries.append(RemovalReport.Entry(subject: .grant(grant), result: .skipped(reason)))
            } else if abort.isFired {
                entries.append(Self.aborted(.grant(grant)))
            } else {
                entries.append(await reset(grant))
            }
        }
        for item in plan.autostartItems {
            if let reason = outdated.autostartItems[item.id] {
                entries.append(RemovalReport.Entry(subject: .autostartItem(item), result: .skipped(reason)))
            } else if abort.isFired {
                entries.append(Self.aborted(.autostartItem(item)))
            } else {
                entries.append(await remove(item))
            }
        }
        var trashed = await trashFiles(files, of: plan.app, abortedBy: abort)[...]
        for file in plan.files {
            if let reason = outdated.files[file.path] {
                entries.append(RemovalReport.Entry(subject: .file(file), result: .skipped(reason)))
            } else if let entry = trashed.popFirst() {
                entries.append(entry)
            }
        }
        return RemovalReport(entries: entries)
    }

    /// Gründe zum Überspringen je Datei-Pfad, `PermissionGrant.id` bzw. `AutostartItem.id` (Struct statt Tupel).
    private struct Outdated {
        var files: [String: String] = [:]
        var grants: [String: String] = [:]
        var autostartItems: [String: String] = [:]
    }

    /// Einträge des Plans, die nach dem aktuellen Stand nicht (mehr) angefasst werden dürfen. Der Scan wird nur
    /// angefordert, wenn es etwas abzugleichen gibt.
    private func outdated(in plan: RemovalPlan) async -> Outdated {
        var outdated = Outdated()
        if let app = plan.app {
            guard !plan.isEmpty else { return outdated }
            let recheck = AppRemovalRecheck(app: app, plan: plan, current: await currentSnapshot(), layout: removalGuard.layout)
            for file in plan.files {
                if let reason = recheck.reason(for: file) { outdated.files[file.path] = reason }
            }
            for grant in plan.grants {
                if let reason = recheck.reason(for: grant) { outdated.grants[grant.id] = reason }
            }
            for item in plan.autostartItems {
                if let reason = recheck.reason(for: item) { outdated.autostartItems[item.id] = reason }
            }
        } else {
            guard !plan.orphanClaims.isEmpty || !plan.autostartItems.isEmpty else { return outdated }
            let recheck = OrphanRecheck(current: await currentSnapshot(), layout: removalGuard.layout)
            for file in plan.files {
                if let claim = plan.orphanClaims[file.path], let reason = recheck.reason(for: claim) { outdated.files[file.path] = reason }
            }
            for item in plan.autostartItems {
                if let reason = recheck.reason(for: item) { outdated.autostartItems[item.id] = reason }
            }
        }
        return outdated
    }

    /// Nicht begonnener Schritt eines abgebrochenen Plans.
    private static func aborted(_ subject: RemovalReport.Subject) -> RemovalReport.Entry {
        RemovalReport.Entry(subject: subject, result: .skipped(abortedReason))
    }

    private func reset(_ grant: PermissionGrant) async -> RemovalReport.Entry {
        do {
            try await permissions.reset(grant)
            return RemovalReport.Entry(subject: .grant(grant), result: .done)
        } catch {
            return RemovalReport.Entry(subject: .grant(grant), result: .failed(ActionCoordinator.message(for: error)))
        }
    }

    private func remove(_ item: AutostartItem) async -> RemovalReport.Entry {
        let receipt: RemovalReceipt
        do {
            receipt = try await autostart.remove(item)
        } catch {
            return RemovalReport.Entry(subject: .autostartItem(item), result: .failed(ActionCoordinator.message(for: error)))
        }
        do {
            try await receipts.add(receipt, label: item.label, removedAt: now())
            return RemovalReport.Entry(subject: .autostartItem(item), result: .done)
        } catch {
            return RemovalReport.Entry(subject: .autostartItem(item), result: .doneWithWarning(
                "Entfernt, aber der Wiederherstellungsbeleg wurde nicht gespeichert: \(error.readableDescription)"
            ))
        }
    }

    private func trashFiles(
        _ files: [LeftoverCandidate], of app: InstalledApp?, abortedBy abort: OneShotSignal
    ) async -> [RemovalReport.Entry] {
        guard !files.isEmpty else { return [] }
        if abort.isFired { return files.map { Self.aborted(.file($0)) } }
        if let app, await runningApps.isRunning(app) {
            return files.map { RemovalReport.Entry(subject: .file($0), result: .skipped(Self.runningReason(app))) }
        }
        let removalGuard = removalGuard
        let verify: @Sendable (LeftoverCandidate) -> RemovalVerdict = { removalGuard.check($0, allowingAppleIDOf: app) }
        let verdicts = files.map(verify)
        var allowed: [LeftoverCandidate] = []
        for (file, verdict) in zip(files, verdicts) {
            switch verdict {
            case .allowed where !allowed.contains(where: { $0.path == file.path }): allowed.append(file)
            case .allowed: break
            case .blocked(let reason): Self.logBlocked(file, reason: reason)
            }
        }
        // Der Papierkorb prüft jeden Kandidaten unmittelbar vor dem Apple Event erneut (Review N2).
        let report = allowed.isEmpty ? TrashReport(outcomes: [:], failure: nil) : await trash.moveToTrash(allowed, verifying: verify)
        return zip(files, verdicts).map { file, verdict in
            RemovalReport.Entry(subject: .file(file), result: Self.result(of: file, verdict: verdict, in: report))
        }
    }

    /// Ergebnis einer Datei nach dem Finder-Auftrag: abgelehnt (vorab oder unmittelbar davor), im Papierkorb, neu
    /// angelegt, noch vorhanden oder ohne Ergebnis.
    static func result(of file: LeftoverCandidate, verdict: RemovalVerdict, in report: TrashReport) -> RemovalReport.Result {
        switch (verdict, report.outcomes[file.path]) {
        case (.blocked(let reason), _), (.allowed, .blocked(let reason)?): .failed("Nicht angefasst: \(reason)")
        case (.allowed, .trashed?): .done
        case (.allowed, .recreated?): .doneWithWarning(recreatedWarning)
        case (.allowed, .remaining(let reason)?): .failed(reason)
        case (.allowed, nil): .failed(report.failure ?? missingFinderResult)
        }
    }

    private static func logBlocked(_ file: LeftoverCandidate, reason: String) {
        logger.notice("Nicht in den Papierkorb (\(reason, privacy: .public)): \(PathDisplay.abbreviatingHome(file.path), privacy: .public)")
    }
}
