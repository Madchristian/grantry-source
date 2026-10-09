import Foundation

extension LeftoverKind {
    /// Abschnittstitel im Entfernen-Blatt bzw. in einer Aufräumen-Gruppe.
    public var displayName: String {
        switch self {
        case .appBundle: "App"
        case .container: "Container"
        case .groupContainer: "Gruppen-Container"
        case .applicationSupport: "Programmdaten"
        case .caches: "Caches"
        case .preferences: "Einstellungen"
        case .savedState: "Fensterzustand"
        case .httpStorage: "Web-Speicher"
        case .webKit: "WebKit-Daten"
        case .logs: "Protokolle"
        case .applicationScripts: "App-Skripte"
        }
    }
}

/// Eine Zeile der Reste-Auswahl; Texte einmal berechnet.
public struct LeftoverRow: Identifiable, Hashable, Sendable {
    /// Der unveränderte Kandidat der Suche (für `RemovalPlanning`).
    public let candidate: LeftoverCandidate
    /// Pfad mit `~`.
    public let pathText: String
    /// „1,2 MB“, „Größe nicht lesbar“, „Größe unbekannt“.
    public let sizeText: String
    /// Sicher (vorausgewählt) oder unsicher – auch, wenn die Suche unvollständig war (`OrphanScanCoverage.incomplete`).
    public let isPreselected: Bool
    /// „Zuordnung sicher“ bzw. „Zuordnung unsicher“ – als Text, nicht nur als Farbe. Gemeint ist, wie sicher der Fund zu
    /// einer gelöschten App gehört, nicht, ob er gefährlich ist.
    public let confidenceText: String
    /// Erklärung zu „Zuordnung unsicher“ (Tooltip).
    public static let uncertainExplanation =
        "Nicht sicher einer gelöschten App zugeordnet – kann noch von einer installierten App oder vom System gebraucht werden. Darum nicht vorausgewählt; vor dem Entfernen prüfen."
    /// Warnhinweis der Suche (z. B. weitere Apps desselben Herstellers).
    public let note: String?
    public let accessibilityLabel: String

    /// Kandidaten-Pfad – zugleich die ID in der `RemovalSelection`.
    public var id: String { candidate.path }

    init(_ candidate: LeftoverCandidate, treatingAsUncertain: Bool, home: String) {
        self.candidate = candidate
        pathText = PathDisplay.abbreviatingHome(candidate.path, home: home)
        sizeText = RemovalSize([candidate]).text
        isPreselected = candidate.isPreselected && !treatingAsUncertain
        confidenceText = isPreselected ? "Zuordnung sicher" : "Zuordnung unsicher"
        note = candidate.note
        accessibilityLabel = [pathText, confidenceText, sizeText, candidate.note.map { "Hinweis: \($0)" }]
            .compactMap(\.self).joined(separator: ", ")
    }
}

/// Kandidaten einer Art (Abschnitt im Entfernen-Blatt bzw. in einer Aufräumen-Gruppe).
public struct LeftoverSection: Identifiable, Hashable, Sendable {
    public let kind: LeftoverKind
    public let rows: [LeftoverRow]
    /// Summe des Abschnitts („mindestens …“, wenn Größen fehlen).
    public let sizeText: String

    public var id: LeftoverKind { kind }
    public var title: String { kind.displayName }

    /// In `LeftoverKind.allCases`-Reihenfolge; leere Arten entfallen, die Reihenfolge innerhalb bleibt.
    /// - Parameter treatingAllAsUncertain: keinen Kandidaten vorauswählen (unvollständige Suche).
    public static func sections(
        _ candidates: [LeftoverCandidate], treatingAllAsUncertain: Bool = false, home: String = NSHomeDirectory()
    ) -> [LeftoverSection] {
        let byKind = Dictionary(grouping: candidates, by: \.kind)
        return LeftoverKind.allCases.compactMap { kind in
            byKind[kind].map { candidates in
                LeftoverSection(
                    kind: kind,
                    rows: candidates.map { LeftoverRow($0, treatingAsUncertain: treatingAllAsUncertain, home: home) },
                    sizeText: RemovalSize(candidates).text
                )
            }
        }
    }
}

/// Auswahl im Entfernen- bzw. Aufräumen-Blatt (IDs: Kandidaten-Pfad, `PermissionGrant.id`, `AutostartItem.id`).
public struct RemovalSelection: Hashable, Sendable {
    public private(set) var selected: Set<String>

    public init(preselected: some Sequence<String>) {
        selected = Set(preselected)
    }

    /// Sichere Kandidaten (Spec v3 §3) sowie alle übergebenen Berechtigungen und Autostart-Einträge.
    public init(candidates: [LeftoverCandidate], grants: [PermissionGrant] = [], autostartItems: [AutostartItem] = []) {
        self.init(preselected: candidates.filter(\.isPreselected).map(\.path) + grants.map(\.id) + autostartItems.map(\.id))
    }

    public func contains(_ id: String) -> Bool { selected.contains(id) }

    public mutating func set(_ id: String, selected isSelected: Bool) {
        if isSelected { selected.insert(id) } else { selected.remove(id) }
    }

    public mutating func toggle(_ id: String) {
        set(id, selected: !contains(id))
    }
}

/// Zusammenfassung einer Auswahl: „Ausgewählt: 3 Objekte (mindestens 1,2 GB), 2 Berechtigungen, 1 Autostart-Eintrag“.
enum RemovalSelectionSummary {
    static func text(
        _ selection: RemovalSelection, rows: [LeftoverRow], grants: [PermissionGrant], autostartItems: [AutostartItem]
    ) -> String {
        let files = rows.filter { selection.contains($0.id) }.map(\.candidate)
        let grantCount = grants.count { selection.contains($0.id) }
        let itemCount = autostartItems.count { selection.contains($0.id) }
        var parts: [String] = []
        if !files.isEmpty { parts.append("\(RemovalTexts.objects(files.count)) (\(RemovalSize(files).text))") }
        if grantCount > 0 { parts.append(grantCount == 1 ? "1 Berechtigung" : "\(grantCount) Berechtigungen") }
        if itemCount > 0 { parts.append(itemCount == 1 ? "1 Autostart-Eintrag" : "\(itemCount) Autostart-Einträge") }
        return parts.isEmpty ? "Nichts ausgewählt" : "Ausgewählt: " + parts.joined(separator: ", ")
    }

    /// „Nicht durchsucht (keine Leserechte): ~/Library/Containers“; `nil` ohne solche Orte.
    static func unreadableNote(_ locations: [String], home: String) -> String? {
        guard !locations.isEmpty else { return nil }
        return "Nicht durchsucht (keine Leserechte): "
            + locations.map { PathDisplay.abbreviatingHome($0, home: home) }.joined(separator: ", ")
    }
}

/// Reste-Auswahl im Blatt „App entfernen“: Kandidaten nach Art, Berechtigungen und Autostart-Einträge der App.
/// Vorausgewählt sind sichere Kandidaten sowie Berechtigungen und Autostart-Einträge, die die `ActionPolicy` zulässt –
/// außer ihre Eigentümerschaft ist mehrdeutig oder nicht belegt (`AppLinks.sharedIDs`): Die sind mit Hinweis
/// sichtbar und nur bewusst wählbar.
public struct RemovalReview: Hashable, Sendable {
    static let sharedNotice = "Dieselbe App ist mehrfach installiert. macOS führt Berechtigungen und Autostart-Einträge nach "
        + "Bundle-ID – was beide Installationen träfe, ist deshalb nicht vorausgewählt."
    static let unverifiedNotice = "Die Zugehörigkeit einzelner Berechtigungen oder Autostart-Einträge ist nicht sicher belegt. "
        + "Eine gleiche Bundle-ID allein reicht dafür nicht; ohne übereinstimmende Team-IDs aus geprüften Signaturen "
        + "sind diese Einträge nicht vorausgewählt."
    static let unverifiedNote = "Zugehörigkeit nicht sicher belegt – kein übereinstimmender Hersteller in den Signaturen."
    public let sections: [LeftoverSection]
    public let grants: [PermissionGrant]
    public let autostartItems: [AutostartItem]
    /// Reste-Orte, die sich nicht lesen ließen; `nil`, wenn alle gelesen wurden.
    public let unreadableNote: String?
    public let initialSelection: RemovalSelection
    /// Erklärung im Blatt bei mehrdeutiger oder nicht belegter Eigentümerschaft; sonst `nil`.
    public let sharedNotice: String?
    private let sharedIDs: Set<String>
    /// „Gehört evtl. auch zu: Tool (~/Applications/Tool.app)“ für `sharedIDs`.
    private let sharedNote: String?

    public init(
        leftovers: LeftoverScanResult, links: AppLinks, policy: ActionPolicy = ActionPolicy(), home: String = NSHomeDirectory()
    ) {
        sections = LeftoverSection.sections(leftovers.candidates, home: home)
        grants = links.grants
        autostartItems = links.autostartItems
        unreadableNote = RemovalSelectionSummary.unreadableNote(leftovers.unreadableLocations, home: home)
        sharedIDs = links.sharedIDs
        sharedNote = OwnershipNote.mayBelong(to: links.otherInstallations.map { OwnershipNote.installation($0, home: home) })
            ?? Self.unverifiedNote
        sharedNotice = links.sharedIDs.isEmpty ? nil
            : (links.otherInstallations.isEmpty ? Self.unverifiedNotice : Self.sharedNotice)
        let preselectable = { (id: String, availability: ActionAvailability) in
            availability == .available && !links.sharedIDs.contains(id)
        }
        initialSelection = RemovalSelection(
            preselected: sections.flatMap(\.rows).filter(\.isPreselected).map(\.id)
                + links.grants.filter { preselectable($0.id, policy.availability(for: $0)) }.map(\.id)
                + links.autostartItems.filter { preselectable($0.id, policy.availability(for: $0)) }.map(\.id)
        )
    }

    /// Hinweis zu einer Berechtigung bzw. einem Autostart-Eintrag (ID); `nil`, wenn er nur diese Installation trifft.
    public func note(for id: String) -> String? {
        sharedIDs.contains(id) ? sharedNote : nil
    }

    /// Anzahl und Größe der Auswahl (Summe „mindestens …“, wenn Größen fehlen).
    public func summary(for selection: RemovalSelection) -> String {
        RemovalSelectionSummary.text(selection, rows: sections.flatMap(\.rows), grants: grants, autostartItems: autostartItems)
    }
}

/// Bereich „Aufräumen“: Reste gelöschter Apps je Kennung, verwaiste Autostart-Einträge und – nur als Hinweis –
/// Berechtigungen entfernter Apps. Die Abdeckung der Suche (`OrphanScanCoverage`) bestimmt, was angeboten wird.
public struct CleanupPresentation: Hashable, Sendable {
    /// Reste einer gelöschten App.
    public struct Group: Identifiable, Hashable, Sendable {
        public let identifier: String
        public let sections: [LeftoverSection]
        /// Summe der Gruppe.
        public let sizeText: String
        /// Mindestens ein Fund ist unsicher.
        public let isUncertain: Bool

        public var id: String { identifier }
    }

    public let groups: [Group]
    /// Verwaiste Autostart-Einträge (Programm fehlt) – über die v1-Aktion entfernbar, vorausgewählt.
    public let autostartItems: [AutostartItem]
    /// Berechtigungen entfernter Apps – nicht auswählbar (`tccutil` braucht die installierte App).
    public let grants: [PermissionGrant]
    /// `grants` je Dienst (nach Name sortiert) – zurücksetzen lässt sich nur der ganze Dienst (`ServiceReset`).
    public var grantServices: [GrantService] {
        Dictionary(grouping: grants, by: \.service)
            .map { GrantService(service: $0.key, grants: $0.value) }
            .sorted { $0.serviceName < $1.serviceName }
    }

    /// Berechtigungen entfernter Apps eines Dienstes (Struct statt Tupel, Leitplanke 2).
    public struct GrantService: Identifiable, Hashable, Sendable {
        public let service: String
        public let grants: [PermissionGrant]
        public var id: String { service }
        public var serviceName: String { PermissionCatalog.service(for: service).displayName }
    }
    /// Hinweis zu `grants`; `nil` ohne solche Berechtigungen.
    public let grantsNote: String?
    /// Warum Funde fehlen oder alle unsicher sind; `nil` bei vollständiger Suche.
    public let coverageNote: String?
    public let unreadableNote: String?
    public let initialSelection: RemovalSelection

    /// Nichts gefunden (weder Reste noch verwaiste Einträge).
    public var isEmpty: Bool { groups.isEmpty && autostartItems.isEmpty && grants.isEmpty }

    public init(result: OrphanScanResult, home: String = NSHomeDirectory()) {
        let treatAsUncertain: Bool
        switch result.coverage {
        case .complete:
            treatAsUncertain = false
            coverageNote = nil
        case .incomplete(let reason):
            treatAsUncertain = true
            coverageNote = "\(reason) – die Zuordnung aller Funde ist unsicher, nichts ist vorausgewählt."
        case .unavailable(let reason):
            treatAsUncertain = true
            coverageNote = "Reste gelöschter Apps lassen sich nicht sicher bestimmen: \(reason)"
        }
        let groups: [Group] = if case .unavailable = result.coverage { [] } else {
            result.groups.map { group in
                let sections = LeftoverSection.sections(group.candidates, treatingAllAsUncertain: treatAsUncertain, home: home)
                return Group(identifier: group.identifier, sections: sections, sizeText: RemovalSize(group.candidates).text,
                             isUncertain: sections.flatMap(\.rows).contains { !$0.isPreselected })
            }
        }
        self.groups = groups
        autostartItems = result.autostartItems
        grants = result.grants
        grantsNote = result.grants.isEmpty ? nil
            : "Einzeln lassen sich Berechtigungen entfernter Apps nicht entfernen – tccutil braucht die installierte App. "
            + "„Für alle Apps zurücksetzen …“ entfernt sie, nimmt die Berechtigung aber auch allen installierten Apps."
        unreadableNote = RemovalSelectionSummary.unreadableNote(result.unreadableLocations, home: home)
        initialSelection = RemovalSelection(
            preselected: groups.flatMap(\.sections).flatMap(\.rows).filter(\.isPreselected).map(\.id)
                + result.autostartItems.map(\.id)
        )
    }

    /// Anzahl und Größe der Auswahl.
    public func summary(for selection: RemovalSelection) -> String {
        RemovalSelectionSummary.text(selection, rows: groups.flatMap(\.sections).flatMap(\.rows), grants: [],
                                     autostartItems: autostartItems)
    }
}
