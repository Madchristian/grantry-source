import Foundation

/// Sortierung der App-Liste.
public enum AppSortOrder: String, Hashable, Sendable, CaseIterable {
    case name, size, lastUsed

    public var title: String {
        switch self {
        case .name: "Name"
        case .size: "Größe"
        case .lastUsed: "Zuletzt benutzt"
        }
    }
}

/// Filter nach Herkunft (`AppOrigin`); „nicht prüfbar“ erscheint nur unter „Alle Herkünfte“.
public enum AppOriginFilter: String, Hashable, Sendable, CaseIterable {
    case all, appStore, homebrew, apple, webApp, direct

    public var title: String {
        switch self {
        case .all: "Alle Herkünfte"
        case .appStore: AppOrigin.appStore.displayName
        case .homebrew: "Homebrew"
        case .apple: AppOrigin.apple.displayName
        case .webApp: "Web-Apps"
        case .direct: AppOrigin.direct.displayName
        }
    }

    func matches(_ origin: AppOrigin) -> Bool {
        switch (self, origin) {
        case (.all, _), (.appStore, .appStore), (.homebrew, .homebrew), (.apple, .apple), (.webApp, .webApp), (.direct, .direct): true
        default: false
        }
    }
}

/// Filter nach Architektur; „unbekannt“ erscheint nur unter „Alle Architekturen“.
public enum AppArchitectureFilter: String, Hashable, Sendable, CaseIterable {
    case all, appleSilicon, intel, universal

    public var title: String {
        architecture?.displayName ?? "Alle Architekturen"
    }

    private var architecture: AppArchitecture? {
        switch self {
        case .all: nil
        case .appleSilicon: .appleSilicon
        case .intel: .intel
        case .universal: .universal
        }
    }

    func matches(_ architecture: AppArchitecture) -> Bool {
        self.architecture.map { $0 == architecture } ?? true
    }
}

/// Filter und Sortierung der App-Liste (Spec v3 §5).
public struct AppListFilter: Hashable, Sendable {
    public var origin: AppOriginFilter
    public var architecture: AppArchitectureFilter
    /// Nur Apps mit Befund (beliebiger Schweregrad).
    public var onlyFlagged: Bool
    public var sort: AppSortOrder

    public init(
        origin: AppOriginFilter = .all, architecture: AppArchitectureFilter = .all, onlyFlagged: Bool = false,
        sort: AppSortOrder = .name
    ) {
        self.origin = origin
        self.architecture = architecture
        self.onlyFlagged = onlyFlagged
        self.sort = sort
    }

    /// Ob ein Filter von der Vorgabe abweicht; die Sortierung zählt nicht.
    public var isActive: Bool { origin != .all || architecture != .all || onlyFlagged }
}

/// Eine Zeile der App-Liste; alle Texte einmal beim Erstellen berechnet (kein Formatieren je Darstellung).
public struct InstalledAppRow: Identifiable, Hashable, Sendable {
    public let app: InstalledApp
    public let details: AppUsageDetails
    /// Höchster Schweregrad der Befunde zur App; `nil` ohne Befund.
    public let severity: RiskFinding.Severity?
    /// „6.0 (600) · Homebrew · Intel“.
    public let subtitle: String
    /// Größe wie im Finder, „–“ solange unbekannt.
    public let sizeText: String
    /// „Zuletzt benutzt gestern“, „Zuletzt benutzt: unbekannt“.
    public let lastUsedText: String
    /// Alles Sichtbare als Satz für VoiceOver – inklusive Schweregrad, der in der Liste nur als Badge erscheint.
    public let accessibilityLabel: String

    public var id: String { app.id }

    init(app: InstalledApp, details: AppUsageDetails, severity: RiskFinding.Severity?, now: Date, calendar: Calendar) {
        self.app = app
        self.details = details
        self.severity = severity
        subtitle = [app.versionText, app.origin.displayName, app.architecture.displayName].compactMap(\.self)
            .joined(separator: " · ")
        let size = details.size.map(AppTexts.formattedSize)
        sizeText = size ?? "–"
        lastUsedText = AppTexts.lastUsed(details.lastUsed, now: now, calendar: calendar)
        accessibilityLabel = [
            app.name, app.versionText.map { "Version \($0)" }, app.originDetail, app.architecture.displayName,
            "Größe " + (size ?? "unbekannt"), lastUsedText, severity.map { "Befund mit Schweregrad \($0.displayName)" },
        ].compactMap(\.self).joined(separator: ", ")
    }
}

/// Filter, Suche und Sortierung der App-Liste. Reine Funktion – die Oberfläche ruft sie nur, wenn sich Apps, Angaben,
/// Befunde, Suche oder Filter ändern, und merkt sich das Ergebnis.
public enum AppInventoryPresenter {
    /// - Parameters:
    ///   - details: nachgeladene Größe und „zuletzt benutzt“ je `InstalledApp.id` (`AppDetailsLoader`).
    ///   - severity: höchster Schweregrad je `InstalledApp.id` (`PresentationSnapshot.highestSeverity(for:)`).
    ///   - query: Suche über Name, Bundle-ID, Entwickler und Cask (ohne Groß-/Kleinschreibung und Akzente).
    public static func rows(
        _ apps: [InstalledApp], details: [String: AppUsageDetails], severity: (String) -> RiskFinding.Severity?,
        query: String, filter: AppListFilter, now: Date, calendar: Calendar = .current
    ) -> [InstalledAppRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = apps
            .filter { filter.origin.matches($0.origin) && filter.architecture.matches($0.architecture) && matches($0, query) }
            .compactMap { app -> InstalledAppRow? in
                let severity = severity(app.id)
                guard !filter.onlyFlagged || severity != nil else { return nil }
                return InstalledAppRow(app: app, details: details[app.id] ?? AppUsageDetails(), severity: severity,
                                       now: now, calendar: calendar)
            }
        return sorted(rows, by: filter.sort)
    }

    private static func matches(_ app: InstalledApp, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var fields = [app.name, app.bundleID, app.signing.developerName]
        if case .homebrew(let cask) = app.origin { fields.append(cask) }
        return fields.contains { $0?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Name aufsteigend (numerisch, ohne Groß-/Kleinschreibung); Größe und zuletzt benutzt absteigend, Unbekanntes
    /// zuletzt; bei Gleichstand nach Name, dann Pfad.
    private static func sorted(_ rows: [InstalledAppRow], by order: AppSortOrder) -> [InstalledAppRow] {
        rows.sorted { lhs, rhs in
            switch order {
            case .name: break
            case .size:
                if let result = descendingWithUnknownLast(lhs.details.size, rhs.details.size) { return result }
            case .lastUsed:
                if let result = descendingWithUnknownLast(lhs.details.lastUsed, rhs.details.lastUsed) { return result }
            }
            let byName = lhs.app.name.compare(rhs.app.name, options: [.caseInsensitive, .numeric, .diacriticInsensitive])
            return byName != .orderedSame ? byName == .orderedAscending : lhs.id < rhs.id
        }
    }

    /// `nil` bei Gleichstand (auch beide unbekannt).
    private static func descendingWithUnknownLast<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs == rhs ? nil : lhs > rhs
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): nil
        }
    }
}

/// Angaben im App-Detail (Spec v3 §5): Herkunft, Architektur, Signatur, Team, Notarisierung, Größe, zuletzt benutzt,
/// Befunde und verknüpfte Berechtigungen bzw. Autostart-Einträge.
public struct InstalledAppDetail: Hashable, Sendable {
    /// Eine beschriftete Angabe. `tone` ergänzt nur – der Text trägt die Aussage allein.
    public struct Fact: Identifiable, Hashable, Sendable {
        public let label: String
        public let value: String
        public let tone: PresentationTone?

        public var id: String { label }
        public var accessibilityLabel: String { "\(label): \(value)" }
    }

    public let app: InstalledApp
    public let facts: [Fact]
    /// Pfad des Bundles mit `~`.
    public let pathText: String
    /// „Signatur nicht geprüft seit 3 Tagen“ u. ä. (`InstalledApp.signingStatusNote(now:calendar:)`); `nil`, wenn aktuell.
    public let signingNote: String?
    /// Höchster Schweregrad zuerst.
    public let findings: [RiskFinding]
    public let grants: [PermissionGrant]
    public let autostartItems: [AutostartItem]

    static let loadingText = "Wird ermittelt …"
    static let unknownText = "Unbekannt"

    /// - Parameter details: nachgeladene Angaben; `nil`, solange sie noch geladen werden.
    public init(
        app: InstalledApp, details: AppUsageDetails?, findings: [RiskFinding], links: AppLinks, now: Date,
        calendar: Calendar = .current, home: String = NSHomeDirectory()
    ) {
        self.app = app
        self.findings = findings
        grants = links.grants
        autostartItems = links.autostartItems
        pathText = PathDisplay.abbreviatingHome(app.path, home: home)
        signingNote = app.signingStatusNote(now: now, calendar: calendar)
        let size = details.map { $0.size.map(AppTexts.formattedSize) ?? Self.unknownText } ?? Self.loadingText
        let lastUsed = details.map { details in
            details.lastUsed.map { AppTexts.lastUsedValue($0, now: now, calendar: calendar) } ?? Self.unknownText
        } ?? Self.loadingText
        var facts = [
            Fact(label: "Version", value: app.versionText ?? Self.unknownText, tone: nil),
            Fact(label: "Herkunft", value: app.originDetail, tone: nil),
            Fact(label: "Architektur", value: app.architecture.displayName, tone: app.architecture == .intel ? .warning : nil),
            Fact(label: "Signatur", value: Self.signingKind(app.signing), tone: app.signing.tone),
            Fact(label: "Team", value: Self.team(app), tone: app.teamIDChange == nil ? nil : .critical),
            Fact(label: "Notarisierung", value: Self.notarization(app.signing), tone: nil),
            Fact(label: "Größe", value: size, tone: nil),
            Fact(label: "Zuletzt benutzt", value: lastUsed, tone: nil),
        ]
        if let bundleID = app.bundleID { facts.append(Fact(label: "Bundle-ID", value: bundleID, tone: nil)) }
        if let target = app.symlinkTarget {
            facts.append(Fact(label: "Verweist auf", value: PathDisplay.abbreviatingHome(target, home: home), tone: .warning))
        }
        self.facts = facts
    }

    /// Signaturart ohne Notarisierung (die steht eigens).
    private static func signingKind(_ signing: SigningInfo) -> String {
        signing.kind == .developerID ? "Developer ID" : signing.displayName
    }

    private static func team(_ app: InstalledApp) -> String {
        let team = app.signing.teamID ?? "Keins"
        return app.teamIDChange.map { "\(team) (vorher \($0.previousTeamID))" } ?? team
    }

    private static func notarization(_ signing: SigningInfo) -> String {
        switch signing.kind {
        case .apple, .appStore: "Nicht nötig (von Apple geprüft)"
        case .developerID: signing.isNotarized ? "Notarisiert" : "Nicht notarisiert"
        case .development, .adHoc, .unsigned: "Nicht notarisiert"
        case .unknown: unknownText
        }
    }
}
