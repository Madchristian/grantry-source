/// Deutscher Kurztext (Titel und Text) einer Änderung, für Benachrichtigungen und UI.
public struct ChangeDescription: Hashable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public init(_ event: ChangeEvent) {
        switch event.subject {
        case .grant(let grant):
            self = Self.describe(event.kind, grant: grant, previous: event.before?.grant)
        case .autostartItem(let item):
            self = Self.describe(event.kind, item: item, previous: event.before?.autostartItem)
        case .securityCheck(let check):
            self = Self.describe(event.kind, check: check, previous: event.before?.securityCheck)
        case .installedApp(let app):
            self = Self.describe(event.kind, app: app, previous: event.before?.installedApp)
        case .networkListener(let listener):
            self = Self.describe(event.kind, listener: listener, previous: event.before?.networkListener)
        case .mcpServer(let server):
            self = Self.describe(event.kind, server: server, previous: event.before?.mcpServer)
        case .agentAutoApproval(let approval):
            self = Self.describe(event.kind, approval: approval, previous: event.before?.agentAutoApproval)
        }
    }

    /// Sammelmeldung „N Änderungen“; der Text nennt die ersten zwei Änderungen, weitere deutet „…“ an.
    public static func summary(for events: [ChangeEvent]) -> ChangeDescription {
        let shown = events.prefix(summaryPreviewCount).map { event in
            let description = ChangeDescription(event)
            return "\(description.title): \(description.body)"
        }
        let lines = events.count > summaryPreviewCount ? shown + ["…"] : shown
        return ChangeDescription(title: "\(events.count) Änderungen", body: lines.joined(separator: "\n"))
    }

    private static let summaryPreviewCount = 2

    /// Nur Verborgenes im Befehl hat sich geändert (Fingerabdruck, #137) – Autostart wie MCP.
    static let maskedCommandChanged = "maskierte Zugangsdaten im Befehl geändert"
}

// MARK: - Berechtigungen

extension ChangeDescription {
    private static func describe(_ kind: ChangeEvent.Kind, grant: PermissionGrant, previous: PermissionGrant?) -> Self {
        let app = grant.client.displayName
        let service = grant.serviceName
        switch kind {
        case .added:
            return Self(title: "Neue Berechtigung", body: addedBody(app: app, service: service, authValue: grant.authValue))
        case .modified:
            let change = previous.map { "\($0.authValue.displayName) → \(grant.authValue.displayName)" } ?? "geändert"
            return Self(title: "Berechtigung geändert", body: "\(app): \(service) \(change).")
        case .removed:
            return Self(title: "Berechtigung entfernt", body: "\(app): \(service)-Eintrag entfernt.")
        }
    }

    private static func addedBody(app: String, service: String, authValue: AuthValue) -> String {
        switch authValue {
        case .allowed: "\(app) darf jetzt \(service)."
        case .limited: "\(app) darf jetzt \(service) (\(authValue.displayName))."
        case .denied, .unknown: "\(app): \(service) \(authValue.displayName)."
        }
    }
}

extension AuthValue {
    /// Deutscher Zustandsname für Kurztexte und Listen.
    public var displayName: String {
        switch self {
        case .allowed: "erlaubt"
        case .denied: "verweigert"
        case .limited: "eingeschränkt"
        case .unknown(let value): "unbekannt (\(value))"
        }
    }
}

// MARK: - Autostart

extension ChangeDescription {
    private static func describe(_ kind: ChangeEvent.Kind, item: AutostartItem, previous: AutostartItem?) -> Self {
        let subject = subjectText(of: item)
        switch kind {
        case .added:
            return Self(title: "Neuer Autostart-Eintrag", body: "\(subject).")
        case .modified:
            let changes = previous.map { changeTexts(from: $0, to: item) } ?? []
            let detail = changes.isEmpty ? "geändert" : changes.joined(separator: ", ")
            return Self(title: "Autostart-Eintrag geändert", body: "\(subject): \(detail).")
        case .removed:
            return Self(title: "Autostart-Eintrag entfernt", body: "\(subject).")
        }
    }

    /// „label (Art)“, mit bekanntem Besitzer ergänzt um „von App“. Heißt die Plist nicht wie ihr Label, steht ihr Name
    /// mit in der Klammer – er unterscheidet Plists mit gleichem Label (`AutostartItem.distinctPlistName`, #138).
    private static func subjectText(of item: AutostartItem) -> String {
        let base = "\(item.label) (\([item.kind.displayName, item.distinctPlistName].compactMap(\.self).joined(separator: ", ")))"
        return item.owner.map { "\(base) von \($0.displayName)" } ?? base
    }

    /// Die gemeldeten Unterschiede in fester Reihenfolge; ein unbekannter Ladezustand und unbekannte Argumente zählen
    /// nicht. Den Befehl selbst nennt der Text nicht – Benachrichtigungen bleiben kurz, Vorher/Nachher zeigt
    /// `ChangeEvent.commandChange`.
    private static func changeTexts(from old: AutostartItem, to new: AutostartItem) -> [String] {
        var texts: [String] = []
        if old.isEnabled != new.isEnabled {
            texts.append(new.isEnabled ? "aktiviert" : "deaktiviert")
        }
        if let wasLoaded = old.isLoaded, let isLoaded = new.isLoaded, wasLoaded != isLoaded {
            texts.append(isLoaded ? "jetzt geladen" : "nicht mehr geladen")
        }
        if new.programDiffers(from: old) {
            texts.append("Programm geändert")
        }
        if new.secretArgumentsDiffer(from: old) {
            texts.append(maskedCommandChanged)
        } else if new.argumentsDiffer(from: old) {
            texts.append("Befehl geändert")
        }
        return texts
    }
}

extension AutostartKind {
    /// Deutscher Name der Eintragsart.
    public var displayName: String {
        switch self {
        case .launchAgent: "LaunchAgent"
        case .launchDaemon: "LaunchDaemon"
        case .loginItem: "Anmeldeobjekt"
        case .backgroundTask: "Hintergrundobjekt"
        }
    }
}

// MARK: - Sicherheit

extension ChangeDescription {
    private static func describe(_ kind: ChangeEvent.Kind, check: SecurityCheck, previous: SecurityCheck?) -> Self {
        let name = check.kind.displayName
        switch kind {
        case .added:
            return Self(title: "Neue Sicherheitsprüfung", body: "\(name): \(check.state.displayName).")
        case .removed:
            return Self(title: "Sicherheitsprüfung entfernt", body: "\(name).")
        case .modified:
            let texts = previous.map { securityChangeTexts(from: $0, to: check) } ?? []
            return Self(title: securityTitle(from: previous, to: check),
                        body: texts.isEmpty ? "\(name) geändert." : texts.joined(separator: ", ") + ".")
        }
    }

    /// Verschlechtert/verbessert nach `effectiveState`; ein MDM-Wechsel ist keine Ampelfrage.
    private static func securityTitle(from previous: SecurityCheck?, to check: SecurityCheck) -> String {
        if check.kind == .mdmEnrollment { return "Geräteverwaltung geändert" }
        guard let old = previous?.effectiveState, let new = check.effectiveState else { return "Sicherheitsstatus geändert" }
        if new.isDeterioration(from: old) { return "Sicherheit verschlechtert" }
        if old.isDeterioration(from: new) { return "Sicherheit verbessert" }
        return "Sicherheitsstatus geändert"
    }

    /// Geänderte Werte in fester Reihenfolge; ohne Wertänderung der Ampelwechsel („Ausstehende Updates: Hinweis →
    /// kritisch“).
    private static func securityChangeTexts(from old: SecurityCheck, to new: SecurityCheck) -> [String] {
        let texts = factChangeTexts(from: old.facts, to: new.facts)
        guard texts.isEmpty, let before = old.effectiveState, let after = new.effectiveState, before != after else {
            return texts
        }
        return ["\(new.kind.displayName): \(before.displayName) → \(after.displayName)"]
    }

    private static func factChangeTexts(from old: SecurityFacts?, to new: SecurityFacts?) -> [String] {
        switch (old, new) {
        case let (.fileVault(before)?, .fileVault(after)?) where before != after:
            return ["FileVault: \(after.displayName)"]
        case let (.firewall(wasEnabled, hadStealth)?, .firewall(isEnabled, hasStealth)?):
            return switchTexts("Firewall", from: wasEnabled, to: isEnabled)
                + switchTexts("Tarnmodus", from: hadStealth, to: hasStealth)
        case let (.sip(before)?, .sip(after)?) where before != after:
            return ["Systemintegritätsschutz \(after.displayName)"]
        case let (.gatekeeper(before)?, .gatekeeper(after)?):
            return switchTexts("Gatekeeper", from: before, to: after)
        case let (.xprotect(before, _)?, .xprotect(after, _)?) where before != after:
            return ["XProtect aktualisiert auf \(after)"]
        case let (.automaticUpdates(before)?, .automaticUpdates(after)?):
            // Die Fakten listen ausgeschaltete Schlüssel: „an“ heißt „nicht enthalten“.
            return SoftwareUpdateKey.allCases.flatMap { key in
                switchTexts(key.displayName, from: !before.contains(key), to: !after.contains(key))
            }
        case let (.pendingUpdates(before, _)?, .pendingUpdates(after, _)?):
            let oldIDs = Set(before.map(\.identifier)), newIDs = Set(after.map(\.identifier))
            return after.filter { !oldIDs.contains($0.identifier) }.map { "Update verfügbar: \($0.displayTitle)" }
                + before.filter { !newIDs.contains($0.identifier) }.map { "Update nicht mehr ausstehend: \($0.displayTitle)" }
        case let (.mdmEnrollment(wasEnrolled, _)?, .mdmEnrollment(isEnrolled, viaDEP)?) where wasEnrolled != isEnrolled:
            return [isEnrolled
                ? "Mac bei einer Geräteverwaltung (MDM) angemeldet" + (viaDEP ? " (automatische Geräteregistrierung)" : "")
                : "Mac nicht mehr bei einer Geräteverwaltung (MDM) angemeldet"]
        default:
            return []
        }
    }

    /// „<Name> eingeschaltet/ausgeschaltet“, wenn sich der Schalter geändert hat.
    private static func switchTexts(_ name: String, from wasOn: Bool, to isOn: Bool) -> [String] {
        guard wasOn != isOn else { return [] }
        return ["\(name) \(isOn ? "eingeschaltet" : "ausgeschaltet")"]
    }
}

// MARK: - Apps

extension ChangeDescription {
    private static func describe(_ kind: ChangeEvent.Kind, app: InstalledApp, previous: InstalledApp?) -> Self {
        switch kind {
        case .added:
            return Self(title: "App installiert", body: "\(app.nameWithVersion) (\(app.origin.displayName)).")
        case .removed:
            return Self(title: "App entfernt", body: "\(app.nameWithVersion).")
        case .modified:
            let texts = previous.map { appChangeTexts(from: $0, to: app) } ?? []
            let detail = texts.isEmpty ? "geändert" : texts.joined(separator: ", ")
            return Self(title: appTitle(from: previous, to: app), body: "\(app.name): \(detail).")
        }
    }

    /// Ein Team-Wechsel geht vor, dann ein Update.
    private static func appTitle(from previous: InstalledApp?, to app: InstalledApp) -> String {
        guard let previous else { return "App geändert" }
        if teamChange(from: previous, to: app) != nil { return "Entwickler-Team einer App geändert" }
        return previous.versionText != app.versionText ? "App aktualisiert" : "App geändert"
    }

    /// „TEAMA → TEAMB“, wenn sich die Team-ID gegenüber der zuletzt bekannten des Vorgängers
    /// (`InstalledApp.referenceTeamID`, auch über eine Zwischenstufe ohne Team) geändert hat; beide bekannt.
    private static func teamChange(from old: InstalledApp, to new: InstalledApp) -> String? {
        guard let before = old.referenceTeamID, let after = new.signing.teamID, before != after else { return nil }
        return "\(before) → \(after)"
    }

    /// Die signifikanten Unterschiede in fester Reihenfolge (wie `InstalledApp.hasSignificantChanges`).
    private static func appChangeTexts(from old: InstalledApp, to new: InstalledApp) -> [String] {
        var texts: [String] = []
        if old.versionText != new.versionText {
            texts.append("Version \(old.versionText ?? "unbekannt") → \(new.versionText ?? "unbekannt")")
        }
        if let change = teamChange(from: old, to: new) {
            texts.append("Team-ID \(change)")
        }
        if let before = old.signing.kind.known, let after = new.signing.kind.known, before != after {
            texts.append("Signatur \(before.shortName) → \(after.shortName)")
        }
        if let before = old.architecture.known, let after = new.architecture.known, before != after {
            texts.append("Architektur \(before.displayName) → \(after.displayName)")
        }
        return texts
    }
}

// MARK: - Hilfen

extension ChangeSubject {
    fileprivate var grant: PermissionGrant? {
        if case .grant(let grant) = self { grant } else { nil }
    }

    fileprivate var autostartItem: AutostartItem? {
        if case .autostartItem(let item) = self { item } else { nil }
    }

    fileprivate var securityCheck: SecurityCheck? {
        if case .securityCheck(let check) = self { check } else { nil }
    }

    fileprivate var installedApp: InstalledApp? {
        if case .installedApp(let app) = self { app } else { nil }
    }

    fileprivate var networkListener: NetworkListener? {
        if case .networkListener(let listener) = self { listener } else { nil }
    }
}
