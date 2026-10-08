import Foundation

/// Texte rund um „Installation beobachten“ (#127).
public enum ObservationTexts {
    public static let userTCCNote = "Kamera, Mikrofon, Automation und andere Berechtigungen des Benutzerbereichs liest "
        + "Grantry nicht – sie fehlen in der Bilanz."
    public static let modifiedNote = "Geänderte Einträge setzt Grantry nicht automatisch zurück – über den Eintrag zur "
        + "passenden Aktion wechseln."
    public static let securityNote = "Sicherheitsprüfungen haben sich während der Beobachtung geändert. Bitte prüfen, ob "
        + "das gewollt war."
    public static let removedNote = "Nur zur Vollständigkeit – entfernte Einträge lassen sich hier nicht zurückholen."
    public static let uncertainExplanation = "Nicht sicher dem beobachteten Tool zugeordnet – kann auch von einer anderen "
        + "App oder vom System stammen, die sich zur selben Zeit geändert haben. Darum nicht vorausgewählt; vor dem "
        + "Entfernen prüfen."
    public static let uncertainBadge = "Zuordnung unsicher"
    /// Warum aus der Beobachtung nur App-Bundles entfernt werden.
    public static let leftoversNote = "Reste der Apps (Einstellungen, Caches, Programmdaten) bleiben liegen – sie können "
        + "schon vor der Beobachtung bestanden haben. Einzeln auswählen über „Mit Resten entfernen …“ bzw. „App entfernen …“."
    public static let likelyBadge = "wahrscheinlich zugehörig"

    /// „Beobachtung „Cursor“ läuft seit 12 Min. – 4 neue Einträge“.
    public static func statusLine(name: String, startedAt: Date, now: Date, addedCount: Int?) -> String {
        let base = "Beobachtung „\(name)“ läuft seit \(duration(from: startedAt, to: now))"
        guard let addedCount else { return base }
        return base + " – " + entries(addedCount, adjective: "neue")
    }

    /// „unter 1 Min.“, „12 Min.“, „2 Std. 5 Min.“, „3 Tagen“.
    public static func duration(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        switch minutes {
        case 0: return "unter 1 Min."
        case ..<60: return "\(minutes) Min."
        case ..<(48 * 60):
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60) Std." : "\(minutes / 60) Std. \(rest) Min."
        default: return "\(minutes / (24 * 60)) Tagen"
        }
    }

    /// „1 neuer Eintrag“, „4 neue Einträge“, „keine neuen Einträge“.
    public static func entries(_ count: Int, adjective: String = "neue") -> String {
        switch count {
        case 0: "keine \(adjective)n Einträge"
        case 1: "1 \(adjective)r Eintrag"
        default: "\(count) \(adjective) Einträge"
        }
    }

    /// Hinweis auf Quellen, die erst während der Beobachtung geliefert haben (Baseline-Regel des `SnapshotDiffer`).
    public static func firstDeliveredNote(_ sourceNames: [String]) -> String? {
        guard !sourceNames.isEmpty else { return nil }
        return "Erst während der Beobachtung lesbar: \(sourceNames.joined(separator: ", ")). Deren Einträge gelten als "
            + "Ausgangsstand und erscheinen nicht als neu."
    }

    /// Hinweis auf Quellen, die beim Start oder Ende nicht lesbar waren.
    public static func failedSourcesNote(_ sourceNames: [String]) -> String? {
        guard !sourceNames.isEmpty else { return nil }
        return "Nicht lesbar beim Start oder Ende: \(sourceNames.joined(separator: ", ")). Die Bilanz ist dort unvollständig."
    }

    /// Hinweis auf Einschränkungen beim Start oder Ende (`ObservationBalance.limitations`), je Zeile „Quelle: Meldung“.
    public static func limitationsNote(_ lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        return "Eingeschränkt beim Start oder Ende – die Bilanz ist dort unvollständig: \(lines.joined(separator: "; "))"
    }

    /// Text einer leeren Bilanz: nur bei vollständiger Abdeckung eine Entwarnung.
    public static func emptyBalanceMessage(isComplete: Bool) -> String {
        isComplete
            ? "Während der Beobachtung ist nichts hinzugekommen, verändert oder verschwunden."
            : "Keine Änderungen erkannt – aber nicht alle Quellen waren vollständig lesbar (siehe Hinweise). "
                + "Das ist keine Entwarnung."
    }

    /// Rückfrage, wenn der Scan beim Start Quellen nicht lesen konnte.
    public static func incompleteStartMessage(_ sourceNames: [String]) -> String {
        "Diese Quellen ließen sich nicht lesen: \(sourceNames.joined(separator: ", ")). Was dort hinzukommt, fehlt in der Bilanz."
    }
}

extension ObservationBalance.Group {
    public var title: String {
        switch self {
        case .newGrants: "Neue Berechtigungen"
        case .newAutostartItems: "Neue Autostart-Einträge"
        case .newApps: "Neue Apps"
        case .newOther: "Weitere neue Einträge"
        case .modified: "Geänderte Einträge"
        case .securityChanges: "Geänderte Sicherheitsprüfungen"
        case .removed: "Entfernte Einträge"
        }
    }

    /// Hinweis unter der Überschrift; `nil` ohne.
    public var note: String? {
        switch self {
        case .modified: ObservationTexts.modifiedNote
        case .securityChanges: ObservationTexts.securityNote
        case .removed: ObservationTexts.removedNote
        case .newGrants, .newAutostartItems, .newApps, .newOther: nil
        }
    }

    public var tone: PresentationTone {
        switch self {
        case .securityChanges: .critical
        case .modified: .warning
        case .newGrants, .newAutostartItems, .newApps, .newOther, .removed: .neutral
        }
    }
}

/// Bilanz zur Anzeige: Abschnitte mit Zeilen und, für neue Einträge, deren Zuordnung.
public struct ObservationBalancePresentation: Hashable, Sendable {
    public struct Row: Identifiable, Hashable, Sendable {
        public let event: ChangeEvent
        public let title: String
        public let body: String
        /// Nur für neue Einträge.
        public let verdict: ObservationAttribution.Verdict?

        public var id: String { "\(event.kind.rawValue)|\(event.subject.recordID)" }
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public let group: ObservationBalance.Group
        public let rows: [Row]
        public var id: ObservationBalance.Group { group }
    }

    public let sections: [Section]
    /// „4 neue, 1 geänderter, 0 entfernte Einträge“.
    public let summary: String

    public init(balance: ObservationBalance, attribution: ObservationAttribution) {
        let groups = balance.groups
        sections = ObservationBalance.Group.allCases.compactMap { group in
            guard let events = groups[group], !events.isEmpty else { return nil }
            return Section(group: group, rows: events.map { event in
                let description = ChangeDescription(event)
                return Row(event: event, title: description.title, body: description.body,
                           verdict: event.kind == .added ? attribution.verdict(for: event.subject) : nil)
            })
        }
        let modified = balance.events.count { $0.kind == .modified }
        let removed = balance.events.count { $0.kind == .removed }
        let counts = "\(balance.addedCount) neu, \(modified) geändert, \(removed) entfernt"
        summary = switch (balance.events.isEmpty, balance.isComplete) {
        case (true, true): "Keine Änderungen während der Beobachtung."
        case (true, false): "Keine Änderungen erkannt – Bilanz unvollständig."
        case (false, true): counts
        case (false, false): counts + " – Bilanz unvollständig"
        }
        emptyMessage = ObservationTexts.emptyBalanceMessage(isComplete: balance.isComplete)
    }

    /// Text, wenn die Bilanz leer ist (`ObservationTexts.emptyBalanceMessage`).
    public let emptyMessage: String

    public var isEmpty: Bool { sections.isEmpty }
}

extension ObservationCleanupCandidate {
    /// „Bedienungshilfen“, „com.example.agent“, „Cursor“.
    public var title: String {
        switch subject {
        case .grant(let grant): grant.serviceName
        case .autostartItem(let item): item.label
        case .installedApp(let app): app.name
        }
    }

    /// „Berechtigung · Cursor“, „LaunchAgent · /Applications/…“, „App · /Applications/Cursor.app“.
    public func detail(home: String = NSHomeDirectory()) -> String {
        switch subject {
        case .grant(let grant): "Berechtigung · \(grant.client.displayName) · \(grant.authValue.displayName)"
        case .autostartItem(let item):
            [item.kind.displayName, item.owner?.displayName ?? item.program.map { PathDisplay.abbreviatingHome($0, home: home) }]
                .compactMap(\.self).joined(separator: " · ")
        case .installedApp(let app): "App · \(PathDisplay.abbreviatingHome(app.path, home: home))"
        }
    }
}

extension PermissionGrant {
    /// Anzeigename des Dienstes, bei Automation mit Ziel.
    public var serviceName: String {
        let name = PermissionCatalog.service(for: service).displayName
        return target.map { "\(name) (Ziel: \($0))" } ?? name
    }
}

extension ActionConfirmation {
    /// Hinweis, dass `tccutil` Automation nur für **alle** Ziele der App zurücksetzt (siehe `PermissionActions`) – beim
    /// Aufräumen aus einer Beobachtung also auch Ziele, die schon vorher bestanden (#156).
    static func automationResetNote(clientName: String) -> String {
        "Setzt alle Automation-Freigaben von \(clientName) zurück – auch Ziele, die vor der Beobachtung bestanden."
    }

    /// Bestätigung vor dem Aufräumen aus einer Beobachtung: jeder Eintrag einzeln (Automation mit Ziel und dem Hinweis
    /// auf alle Ziele der App), Apps mit Zahl und Größe ihrer Reste.
    public static func observationCleanup(
        _ plan: ObservationCleanupPlan, name: String, home: String = NSHomeDirectory()
    ) -> ActionConfirmation {
        var lines: [String] = []
        let grants = plan.grants + plan.appRemovals.flatMap(\.grants)
        for grant in grants {
            lines.append("Berechtigung zurücksetzen: \(RemovalReport.Subject.grant(grant).displayName(home: home))")
        }
        for item in plan.autostartItems + plan.appRemovals.flatMap(\.autostartItems) {
            lines.append("Autostart-Eintrag entfernen (mit Sicherung): \(RemovalReport.Subject.autostartItem(item).displayName(home: home))")
        }
        for removal in plan.appRemovals {
            guard let app = removal.app else { continue }
            for file in removal.files {
                let name = file.kind == .appBundle ? "„\(app.name)“" : PathDisplay.abbreviatingHome(file.path, home: home)
                lines.append("In den Papierkorb: \(name) (\(RemovalSize([file]).text))")
            }
        }
        let hasFiles = plan.appRemovals.contains { !$0.files.isEmpty }
        var notes: [String] = []
        var automationClients: [String] = []
        for grant in grants where grant.service == PermissionCatalog.automationServiceID {
            let client = grant.client.displayName
            if !automationClients.contains(client) { automationClients.append(client) }
        }
        notes += automationClients.map(automationResetNote(clientName:))
        if hasFiles {
            notes.append(RemovalTexts.restoreHint + " Bei geschützten Dateien fragt macOS nach dem Passwort.")
            notes.append(ObservationTexts.leftoversNote)
        }
        return ActionConfirmation(
            title: "Aus „\(name)“ entfernen?",
            message: lines.joined(separator: "\n"),
            note: notes.isEmpty ? nil : notes.joined(separator: "\n"),
            confirmTitle: hasFiles ? "Entfernen und in den Papierkorb legen" : "Entfernen",
            isDestructive: true
        )
    }
}
