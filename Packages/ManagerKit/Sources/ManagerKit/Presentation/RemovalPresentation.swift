import Foundation

extension RemovalPlan {
    /// „1,2 GB“, „mindestens 1,2 GB“, „mindestens 1,2 GB, 1 Größe nicht lesbar“, „Größe unbekannt“ bzw. „Größe nicht lesbar“.
    public var sizeText: String { RemovalSize(files).text }
}

extension ActionOutcomePresentation {
    /// Ergebnis von `ActionCoordinator.performRemoval(_:)`: Erledigtes als Satz, Nicht-Erledigtes und Warnungen je Eintrag
    /// mit Grund. Haben alle Einträge denselben Grund (App läuft, keine Freigabe …), ist er die Meldung selbst.
    public static func removal(_ report: RemovalReport, home: String = NSHomeDirectory()) -> ActionOutcomePresentation {
        if report.automationDenied {
            return ActionOutcomePresentation(
                text: RemovalExecutor.automationDeniedReason, tone: .critical, settingsURL: TrashPermission.settingsURL, details: []
            )
        }
        let done = report.entries.filter(\.result.isDone)
        let open = report.entries.filter { !$0.result.isDone }
        let commonReason = Set(open.map(\.result.reason))
        if done.isEmpty, commonReason.count == 1, let reason = commonReason.first ?? nil {
            return ActionOutcomePresentation(text: reason, tone: .critical, settingsURL: nil, details: [])
        }
        let details = (open + done).compactMap { entry in
            entry.result.reason.map { "\(entry.subject.displayName(home: home)): \($0)" }
        }
        let tone: PresentationTone = if done.isEmpty {
            open.isEmpty ? .warning : .critical
        } else {
            details.isEmpty ? .positive : .warning
        }
        return ActionOutcomePresentation(text: summary(of: done), tone: tone, settingsURL: nil, details: details)
    }

    /// „In den Papierkorb gelegt: 3 Objekte (1,2 GB); Berechtigungen zurückgesetzt: 2; …“.
    private static func summary(of done: [RemovalReport.Entry]) -> String {
        var files: [LeftoverCandidate] = []
        var grants = 0, items = 0
        for entry in done {
            switch entry.subject {
            case .file(let file): files.append(file)
            case .grant: grants += 1
            case .autostartItem: items += 1
            }
        }
        var parts: [String] = []
        if !files.isEmpty { parts.append("In den Papierkorb gelegt: \(RemovalTexts.objects(files.count)) (\(RemovalSize(files).text))") }
        if grants > 0 { parts.append("Berechtigungen zurückgesetzt: \(grants)") }
        if items > 0 { parts.append("Autostart-Einträge entfernt: \(items)") }
        guard !parts.isEmpty else { return "Nichts wurde entfernt." }
        return parts.joined(separator: "; ") + "." + (files.isEmpty ? "" : " " + RemovalTexts.restoreHint)
    }
}

extension RemovalReport.Subject {
    /// Pfad mit `~`, „Kamera-Berechtigung von Zoom“ (Automation mit Ziel) bzw. „„label““.
    func displayName(home: String) -> String {
        switch self {
        case .file(let file): PathDisplay.abbreviatingHome(file.path, home: home)
        case .grant(let grant): "\(grant.serviceName)-Berechtigung von \(grant.client.displayName)"
        case .autostartItem(let item): "„\(item.label)“"
        }
    }
}

extension ActionOutcomePresentation {
    /// Ergebnis von „Grantry deinstallieren …“, in jedem Fall aus denselben Abschnitten (#143):
    ///
    /// 1. Ursache – fehlende Finder-Freigabe bzw. der blockierende Schritt, unabhängig vom Stand von Grantry.
    /// 2. Stand – vollständig (`SelfUninstallReport.isComplete`, Grantry beendet sich), im Papierkorb mit Resten oder
    ///    nicht entfernt.
    /// 3. Nicht entfernt: was bereits verändert ist. Im Papierkorb: je Kategorie offener Reste (Dienste, Berechtigungen,
    ///    Dateien) ein Abschnitt mit konkretem Weg, sie selbst zu entfernen.
    ///
    /// Details nennen echte Fehler je Eintrag; nicht angemeldete, ausgelassene und ohne Finder-Freigabe nicht
    /// angefasste Gegenstände sind kein eigener Befund.
    public static func selfUninstall(_ report: SelfUninstallReport, home: String = NSHomeDirectory()) -> ActionOutcomePresentation {
        let failure = report.finderAccessFailure
        let silentReasons = Set([SelfUninstaller.notRegisteredReason, SelfUninstaller.blockedReason] + [failure].compactMap(\.self))
        let details = report.entries.compactMap { entry -> String? in
            guard let reason = entry.result.reason, !silentReasons.contains(reason) else { return nil }
            return "\(entry.subject.displayName(home: home)): \(reason)"
        }

        var sentences = [failure].compactMap(\.self)
        if let blocker = report.blockedBy { sentences.append(SelfUninstallTexts.blocked(by: blocker)) }
        if report.isComplete {
            sentences += [SelfUninstallTexts.removed, RemovalTexts.restoreHint]
        } else if report.appRemoved {
            sentences.append(SelfUninstallTexts.inTrash)
            sentences += SelfUninstallTexts.leftovers(report, home: home)
            sentences.append(RemovalTexts.restoreHint)
        } else {
            sentences.append(SelfUninstallTexts.notRemoved)
            sentences += SelfUninstallTexts.changesSoFar(report, home: home)
        }
        let tone: PresentationTone = if report.isComplete {
            details.isEmpty ? .positive : .warning
        } else if report.appRemoved, failure == nil, report.servicesStillRegistered.isEmpty {
            .warning
        } else {
            .critical
        }
        return ActionOutcomePresentation(
            text: sentences.joined(separator: " "), tone: tone,
            settingsURL: report.automationDenied ? TrashPermission.settingsURL : nil, details: details
        )
    }
}

enum SelfUninstallTexts {
    static let removed = "Grantry liegt im Papierkorb und wird jetzt beendet."
    static let inTrash = "Grantry liegt im Papierkorb."

    /// Reste bei entsorgtem Bundle, je Kategorie mit konkretem manuellem Weg (#143).
    static func leftovers(_ report: SelfUninstallReport, home: String) -> [String] {
        let services = report.servicesStillRegistered.map { $0.displayName(home: home) }
        let grants = report.grantsLeftBehind
        let files = report.filesLeftBehind.map { PathDisplay.abbreviatingHome($0.path, home: home) }
        return (services.isEmpty ? [] : [stillRegistered(services)])
            + (grants.isEmpty ? [] : [grantsLeftBehind(grants, home: home)])
            + (files.isEmpty ? [] : [filesLeftBehind(files)])
    }

    /// Nicht zurückgesetzte Berechtigungen: je Berechtigung Ort in den Systemeinstellungen und `tccutil`-Befehl.
    static func grantsLeftBehind(_ grants: [PermissionGrant], home: String) -> String {
        let ways = grants.map { grant in
            let bundleID = grant.client.bundleID ?? GrantryIdentity.appBundleID
            return "\(RemovalReport.Subject.grant(grant).displayName(home: home)) (Systemeinstellungen › Datenschutz & "
                + "Sicherheit › \(PermissionCatalog.service(for: grant.service).displayName) oder im Terminal: "
                + "tccutil reset \(PermissionActions.tccutilServiceName(grant.service)) \(bundleID))"
        }
        return "Nicht zurückgesetzt: \(ways.joined(separator: "; ")). „Erneut versuchen“ wiederholt das."
    }

    /// Grantry ist im Papierkorb, gewählte Dateien aber nicht (#143): Sie bleiben, bis der Nutzer sie selbst entsorgt.
    static func filesLeftBehind(_ paths: [String]) -> String {
        "Nicht im Papierkorb: \(paths.joined(separator: ", ")). Bei Bedarf im Finder selbst in den Papierkorb legen."
    }

    /// Grantry ist im Papierkorb, aber Dienste sind noch angemeldet (#143): Was zurückbliebe und wie es weggeht.
    static func stillRegistered(_ names: [String]) -> String {
        "Noch bei macOS angemeldet: \(names.joined(separator: ", ")) – nach dem Beenden bliebe das verwaist zurück. "
            + "„Erneut versuchen“ wiederholt die Abmeldung; sonst unter Systemeinstellungen › Allgemein › "
            + "Anmeldeobjekte & Erweiterungen entfernen."
    }
    static let notRemoved = "Grantry wurde nicht entfernt."
    /// Was nach dem gescheiterten Schritt ausblieb und wie es weitergeht (#156, #140).
    static func blocked(by subject: SelfUninstallReport.Subject) -> String {
        switch subject {
        case .helper, .loginItem:
            "„\(subject.displayName(home: NSHomeDirectory()))“ ließ sich nicht abmelden – die folgenden Schritte wurden "
                + "ausgelassen."
        case .grant:
            "Eine Berechtigung ließ sich nicht zurücksetzen – die folgenden Schritte wurden ausgelassen."
        case .file:
            "Die Automation-Freigabe für den Finder bleibt für einen erneuten Versuch erhalten."
        }
    }

    /// Was bereits verändert ist, obwohl Grantry noch installiert ist: Dienste und Berechtigungen sind vor dem
    /// Papierkorb schon zurückgenommen, Teile der Auswahl ggf. schon im Papierkorb – das muss der Nutzer erfahren.
    static func changesSoFar(_ report: SelfUninstallReport, home: String) -> [String] {
        let done = report.entries.filter(\.result.isDone)
        let undone = done.filter { if case .file = $0.subject { false } else { true } }.map { $0.subject.displayName(home: home) }
        let trashed = done.count - undone.count
        return (undone.isEmpty ? [] : [alreadyUndone(undone)]) + (trashed == 0 ? [] : [alreadyTrashed(trashed)])
    }

    static func alreadyTrashed(_ count: Int) -> String {
        "Bereits im Papierkorb: \(RemovalTexts.objects(count)). " + RemovalTexts.restoreHint
    }

    /// Was vor dem abgebrochenen Papierkorb schon abgemeldet bzw. zurückgesetzt war.
    static func alreadyUndone(_ names: [String]) -> String {
        "Bereits abgemeldet bzw. zurückgesetzt: \(names.joined(separator: ", ")). "
            + "Hintergrunddienst und „Beim Anmelden starten“ in der Einrichtung, Berechtigungen in den Systemeinstellungen neu einrichten."
    }
}

extension SelfUninstallReport.Subject {
    func displayName(home: String) -> String {
        switch self {
        case .helper: "Hintergrunddienst"
        case .loginItem: "Beim Anmelden starten"
        case .grant(let grant): RemovalReport.Subject.grant(grant).displayName(home: home)
        case .file(let file): RemovalReport.Subject.file(file).displayName(home: home)
        }
    }
}

enum RemovalTexts {
    static let restoreHint = "Wiederherstellen über „Zurücklegen“ im Papierkorb."

    static func objects(_ count: Int) -> String { count == 1 ? "1 Objekt" : "\(count) Objekte" }
}

extension ActionConfirmation {
    /// Bestätigung vor „App entfernen“ bzw. „Aufräumen“ – mit Summe der Größe (Spec v3 §3 Schritt 3) und den Reste-Orten,
    /// die nicht durchsucht werden konnten.
    public static func removal(_ plan: RemovalPlan, home: String = NSHomeDirectory()) -> ActionConfirmation {
        var lines: [String] = []
        if !plan.files.isEmpty { lines.append("In den Papierkorb: \(RemovalTexts.objects(plan.files.count)) (\(plan.sizeText))") }
        if !plan.grants.isEmpty { lines.append("Berechtigungen zurücksetzen: \(plan.grants.count)") }
        if !plan.autostartItems.isEmpty { lines.append("Autostart-Einträge entfernen: \(plan.autostartItems.count) (mit Sicherung)") }
        var notes: [String] = []
        if !plan.files.isEmpty {
            notes.append(RemovalTexts.restoreHint + " Bei geschützten Dateien fragt macOS nach dem Passwort.")
        }
        if !plan.unreadableLocations.isEmpty {
            let locations = plan.unreadableLocations.map { PathDisplay.abbreviatingHome($0, home: home) }
            notes.append("Nicht durchsucht (keine Leserechte): \(locations.joined(separator: ", "))")
        }
        return ActionConfirmation(
            title: plan.app.map { "„\($0.name)“ entfernen?" } ?? (plan.files.isEmpty ? "Reste entfernen?" : "Reste in den Papierkorb legen?"),
            message: lines.joined(separator: "\n"),
            note: notes.isEmpty ? nil : notes.joined(separator: "\n"),
            confirmTitle: plan.files.isEmpty ? "Entfernen" : "In den Papierkorb legen",
            isDestructive: true
        )
    }
}
