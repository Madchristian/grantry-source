import Foundation
import GrantryShared

// Darstellung des Bereichs „Erweiterungen“ (TM-13.5, Spec 2026-11-08 § 5.2): Rechte-Schichten, Bewertung je
// Erweiterung, Zustandszeile, ruhiges Urteil und Detail mit Aktionen. Rein aus Snapshot, Befunden und Akzeptanz; die
// App ordnet Töne und Symbole der Instrumententafel zu.

/// Ton einer Angabe; die App ordnet ihn den Zustandstönen der Instrumententafel zu (`StatusTone`).
public enum ExtensionTone: Hashable, Sendable {
    case positive, info, neutral, finding, critical
}

/// Bewertung einer Erweiterung in Tabelle, Radar und Detail; `nil` heißt unauffällig.
public enum ExtensionRating: Hashable, Sendable, CaseIterable {
    case critical, finding, notice, accepted

    public var title: String {
        switch self {
        case .critical: String(localized: "kritisch")
        case .finding: String(localized: "auffällig")
        case .notice: String(localized: "Hinweis")
        case .accepted: String(localized: "akzeptiert")
        }
    }

    public var tone: ExtensionTone {
        switch self {
        case .critical: .critical
        case .finding: .finding
        case .notice: .info
        case .accepted: .neutral
        }
    }

    /// Auffällig oder kritisch: Befund-Punkt in Tabelle und Radar, zählt im Urteil.
    public var isFinding: Bool { self == .critical || self == .finding }

    /// Bewertung aus dem schwersten Befund; eine Akzeptanz geht vor.
    static func of(_ findings: [RiskFinding], isAccepted: Bool) -> ExtensionRating? {
        if isAccepted { return .accepted }
        return switch findings.map(\.severity).max() {
        case .high?: .critical
        case .medium?: .finding
        case .low?: .notice
        case nil: nil
        }
    }

    /// Reihenfolge in einer Schicht: Auffälliges zuerst.
    var rank: Int {
        switch self {
        case .critical: 0
        case .finding: 1
        case .notice: 2
        case .accepted: 3
        }
    }
}

/// Filter über der Tabelle: alle, nur auffällige oder eine Schicht.
public enum ExtensionFilter: Hashable, Sendable, CaseIterable {
    case all, findings, kernel, systemExtension, driver, servicePlugin

    public var title: String {
        switch self {
        case .all: String(localized: "Alle")
        case .findings: String(localized: "Auffällig")
        case .kernel: String(localized: "Im Kern")
        case .systemExtension: String(localized: "Sonderrechte")
        case .driver: String(localized: "Treiber")
        case .servicePlugin: String(localized: "Plug-ins")
        }
    }

    func includes(_ row: ExtensionRow) -> Bool {
        switch self {
        case .all: true
        case .findings: row.rating?.isFinding == true
        case .kernel: row.layer == .kernel
        case .systemExtension: row.layer == .systemExtension
        case .driver: row.layer == .driver
        case .servicePlugin: row.layer == .servicePlugin
        }
    }
}

extension ExtensionLayer {
    /// Kurzer Titel am Ring des Radars.
    public var ringTitle: String {
        switch self {
        case .kernel: String(localized: "im Kern")
        case .systemExtension: String(localized: "Sonderrechte")
        case .driver: String(localized: "Treiber")
        case .servicePlugin: String(localized: "Plug-ins")
        }
    }

    /// Ein Satz, was die Schicht bedeutet (Liste unter dem Radar).
    public var explanation: String {
        switch self {
        case .kernel: String(localized: "Kernel-Erweiterungen: voller Zugriff auf Speicher, Geräte und alle Prozesse.")
        case .systemExtension:
            String(localized: "Netzwerk, Endpoint Security und Kamera: außerhalb des Kerns, mit Blick auf alle Apps.")
        case .driver: String(localized: "DriverKit-Treiber sprechen direkt mit einem Gerät.")
        case .servicePlugin: String(localized: "Audio- und Video-Plug-ins, die ein Dienst von macOS lädt.")
        }
    }
}

extension ExtensionKind {
    /// SF Symbol der Art (dekorativ; die Art steht als Text daneben).
    public var symbol: String {
        switch self {
        case .kernelExtension: "cpu"
        case .driver: "cable.connector"
        case .network: "network"
        case .endpointSecurity: "eye"
        case .camera: "video"
        case .otherSystemExtension: "puzzlepiece.extension"
        case .audioPlugin: "speaker.wave.2"
        case .videoPlugin: "web.camera"
        }
    }
}

extension ExtensionState {
    /// Läuft: positiv; wartet auf Freigabe: Hinweis; sonst neutral.
    public var tone: ExtensionTone {
        switch self {
        case .enabled, .loaded: .positive
        case .waitingForUser: .info
        case .disabled, .removalPending, .notLoaded, .installed, .unknown: .neutral
        }
    }
}

extension ExtensionOwnership {
    /// Name der zugehörigen App aus ihrem Pfad, einzeilig und gekürzt; `nil` ohne eindeutige App.
    public var appName: String? {
        guard case .app(let path, _) = self else { return nil }
        return ExtensionText.name(URL(filePath: path).deletingPathExtension().lastPathComponent)
    }
}

/// Eine Erweiterung mit ihrer Bewertung.
public struct ExtensionRow: Identifiable, Hashable, Sendable {
    static let maximumRadarLabelLength = 14

    public let record: ExtensionRecord
    public let rating: ExtensionRating?
    /// Befunde und Hinweise der Sicherheitsbewertung, schwerste zuerst.
    public let findings: [RiskFinding]

    public var id: String { record.id }
    public var layer: ExtensionLayer { record.layer }
    public var title: String { ExtensionTexts.label(of: record) }
    /// Entwicklername der Signatur, sonst die zugehörige App; `nil`, wenn beides fehlt.
    public var vendor: String? { record.signing?.developerName.map(ExtensionText.name) ?? record.owner?.appName }
    public var teamText: String { record.teamID ?? String(localized: "ohne Team-ID") }
    public var versionText: String { record.versionText ?? "–" }
    /// Kurzname am Echo im Radar.
    public var radarLabel: String { DisplayText.singleLine(title, maximumLength: Self.maximumRadarLabelLength) }

    /// Teil von Name, Bundle-ID, Hersteller oder Team-ID, ohne Groß-/Kleinschreibung.
    func matches(_ query: String) -> Bool {
        [title, record.bundleID, vendor, record.teamID].compactMap(\.self)
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Eine Rechte-Schicht mit ihren Erweiterungen.
public struct ExtensionLayerGroup: Identifiable, Hashable, Sendable {
    public let layer: ExtensionLayer
    public let rows: [ExtensionRow]
    /// Zusatz, etwa ausgeblendete Plug-ins von Apple.
    public let note: String?

    public var id: ExtensionLayer { layer }
    public var findingCount: Int { rows.count { $0.rating?.isFinding == true } }
}

/// Zustandszeile des Bereichs.
public struct ExtensionVerdict: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public let text: String
        public let tone: ExtensionTone

        public init(text: String, tone: ExtensionTone) {
            self.text = text
            self.tone = tone
        }
    }

    public let title: String
    public let level: SystemVerdict.Level
    public let items: [Item]
    public let facts: String
}

/// Seiten der Systemeinstellungen, in denen macOS Erweiterungen verwaltet.
public enum ExtensionSettingsLinks {
    /// Allgemein › Anmeldeobjekte & Erweiterungen: Systemerweiterungen und Treiber.
    public static let systemExtensions = ActionAvailability.Reason.loginItemsSettingsURL
    /// Datenschutz & Sicherheit: Freigabe von Kernel-Erweiterungen.
    public static let kernelExtensions = SecuritySettingsLinks.privacyAndSecurity
}

/// Aktion im Detail einer Erweiterung.
public enum ExtensionAction: Hashable, Sendable {
    case openSettings(URL)
    case showApp(path: String)
    case revealInFinder(String)
    /// Nur Plug-ins anderer Hersteller; die App fragt vorher nach und legt über den Finder in den Papierkorb.
    case moveToTrash
}

/// Detail der gewählten Erweiterung.
public struct ExtensionDetail: Hashable, Sendable {
    public struct Finding: Hashable, Sendable {
        public let text: String
        public let tone: ExtensionTone
    }

    public struct Fact: Hashable, Sendable {
        public let title: String
        public let value: String
        public let isCode: Bool

        init(_ title: String, _ value: String, isCode: Bool = false) {
            self.title = title
            self.value = value
            self.isCode = isCode
        }
    }

    /// Eigene Einschätzung: anbieten (Befund ab mittel) oder als akzeptiert zeigen.
    public enum Acceptance: Hashable, Sendable {
        case offered, accepted

        public var text: String {
            switch self {
            case .offered:
                String(localized: "Vertraust du ihr, blendet „Risiko akzeptieren“ den Befund aus; bei einem anderen Team warnt Grantry erneut.")
            case .accepted:
                String(localized: "Akzeptiert: Der Befund fehlt in Zustandszeile und Wachbuch; bei einem anderen Team warnt Grantry erneut.")
            }
        }
    }

    public let row: ExtensionRow
    /// „Endpoint Security · gehört zu Vendor“.
    public let subtitle: String
    public let permission: String
    public let findings: [Finding]
    public let acceptance: Acceptance?
    public let facts: [Fact]
    public let actions: [ExtensionAction]

    init(row: ExtensionRow, calendar: Calendar) {
        let record = row.record
        self.row = row
        subtitle = "\(record.kind.displayName) · \(Self.ownerPhrase(record.owner))"
        permission = record.kind.permissionText
        findings = row.findings.map { finding in
            Finding(text: finding.message + ".", tone: row.rating == .accepted ? .neutral : Self.tone(finding.severity))
        }
        acceptance = row.rating == .accepted ? .accepted
            : row.findings.contains { $0.severity >= .medium } ? .offered : nil
        facts = Self.facts(of: row, calendar: calendar)
        actions = Self.actions(for: record)
    }

    static func tone(_ severity: RiskFinding.Severity) -> ExtensionTone {
        switch severity {
        case .high: .critical
        case .medium: .finding
        case .low: .info
        }
    }

    private static func ownerPhrase(_ owner: ExtensionOwnership?) -> String {
        switch owner {
        case .app?: String(localized: "gehört zu \(owner?.appName ?? "")")
        case .missing?: String(localized: "ohne installierte App")
        case .unclear?, nil: String(localized: "ohne bekannte App")
        }
    }

    private static func facts(of row: ExtensionRow, calendar: Calendar) -> [Fact] {
        let record = row.record
        var facts = [
            Fact(String(localized: "Hersteller"), row.vendor ?? String(localized: "unbekannt")),
            Fact(String(localized: "Team-ID"), row.teamText, isCode: record.teamID != nil),
            Fact(String(localized: "Bundle-ID"), record.bundleID, isCode: true),
            Fact(String(localized: "Version"), row.versionText),
        ]
        if !record.otherVersions.isEmpty {
            facts.append(Fact(String(localized: "Weitere Versionen"), record.otherVersions.joined(separator: ", ")))
        }
        facts += [
            Fact(String(localized: "Signatur"), signingText(record)),
            Fact(String(localized: "Zugehörige App"), ownerText(record.owner)),
            Fact(String(localized: "Erstmals gesehen"),
                 record.firstSeenAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar,
                                                               timeZone: calendar.timeZone))),
        ]
        if let path = record.path {
            facts.append(Fact(String(localized: "Pfad"), DisplayText.singleLine(PathDisplay.abbreviatingHome(path)),
                              isCode: true))
        }
        return facts
    }

    /// Systemerweiterungen prüft macOS bei der Aktivierung; maßgeblich ist das gemeldete Team.
    static func signingText(_ record: ExtensionRecord) -> String {
        if record.kind.group == .systemExtensions {
            return record.teamID == nil ? String(localized: "nicht prüfbar (kein Team)")
                : String(localized: "prüft macOS bei der Aktivierung")
        }
        guard record.isSigningConclusive else { return String(localized: "Prüfung nicht rechtzeitig beendet") }
        return record.signing?.displayName ?? String(localized: "unbekannt")
    }

    private static func ownerText(_ owner: ExtensionOwnership?) -> String {
        switch owner {
        case .app?: owner?.appName ?? ""
        case .missing?: String(localized: "fehlt")
        case .unclear(let candidates)?:
            candidates.isEmpty ? String(localized: "nicht eindeutig")
                : String(localized: "nicht eindeutig (\(candidates.count) Apps)")
        case nil: String(localized: "unbekannt")
        }
    }

    /// Kernel- und Systemerweiterungen entfernt Grantry nicht (Deinstallation über die App des Herstellers); in den
    /// Papierkorb dürfen nur Plug-ins anderer Hersteller mit bekanntem Pfad.
    static func actions(for record: ExtensionRecord) -> [ExtensionAction] {
        let settings: URL? = switch record.kind.group {
        case .systemExtensions: ExtensionSettingsLinks.systemExtensions
        case .kernelExtensions: ExtensionSettingsLinks.kernelExtensions
        case .servicePlugins: nil
        }
        var actions = settings.map { [ExtensionAction.openSettings($0)] } ?? []
        if case .app(let path, _)? = record.owner { actions.append(.showApp(path: path)) }
        if let path = record.path { actions.append(.revealInFinder(path)) }
        if record.kind.group == .servicePlugins, record.path != nil, record.signing?.isAppleSigned != true {
            actions.append(.moveToTrash)
        }
        return actions
    }
}

/// Inhalt des Bereichs „Erweiterungen“ für Suche, Filter und Auswahl.
public struct ExtensionPresentation: Sendable {
    /// Ohne Plug-ins von Apple, nach Schicht, darin Auffälliges zuerst, dann nach Name.
    public let all: [ExtensionRow]
    /// Nach Filter und Suche.
    public let rows: [ExtensionRow]
    public let hiddenApplePlugins: Int
    /// Abdeckung der Quelle; nur eine vollständige Prüfung erlaubt das ruhige Urteil.
    public let coverage: AreaCoverage?

    /// - Parameters:
    ///   - findings: ungefilterte Befunde der Erweiterungen (`MonitoringState.extensionFindings`).
    ///   - acceptedIDs: akzeptierte Erweiterungen (`MonitoringState.acceptedExtensionIDs`).
    public init(records: [ExtensionRecord], findings: [RiskFinding], acceptedIDs: Set<String>, filter: ExtensionFilter,
                query: String, coverage: AreaCoverage?) {
        let findingsByID = Dictionary(grouping: findings, by: \.recordID)
        all = records.filter { !$0.isApplePlugin }
            .map { record in
                let own = (findingsByID[record.id] ?? []).sorted { $0.severity > $1.severity }
                return ExtensionRow(record: record, rating: .of(own, isAccepted: acceptedIDs.contains(record.id)),
                                    findings: own)
            }
            .sorted(by: Self.displayOrder)
        hiddenApplePlugins = records.count(where: \.isApplePlugin)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = all.filter { filter.includes($0) && (query.isEmpty || $0.matches(query)) }
        self.coverage = coverage
    }

    private static func displayOrder(_ lhs: ExtensionRow, _ rhs: ExtensionRow) -> Bool {
        if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
        let (left, right) = (lhs.rating?.rank ?? Int.max, rhs.rating?.rank ?? Int.max)
        if left != right { return left < right }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    /// Alle vier Schichten von innen nach außen, unabhängig von Filter und Suche.
    public var layers: [ExtensionLayerGroup] { Self.groups(all, hiddenApplePlugins: hiddenApplePlugins) }

    /// Schichten mit Treffern für die Tabelle.
    public var sections: [ExtensionLayerGroup] {
        Self.groups(rows, hiddenApplePlugins: hiddenApplePlugins).filter { !$0.rows.isEmpty }
    }

    private static func groups(_ rows: [ExtensionRow], hiddenApplePlugins: Int) -> [ExtensionLayerGroup] {
        ExtensionLayer.allCases.map { layer in
            ExtensionLayerGroup(layer: layer, rows: rows.filter { $0.layer == layer },
                                note: layer == .servicePlugin ? hiddenText(hiddenApplePlugins) : nil)
        }
    }

    /// „1 Plug-in von Apple ausgeblendet“; `nil` ohne ausgeblendete.
    private static func hiddenText(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: String(localized: "1 Plug-in von Apple ausgeblendet")
        default: String(localized: "\(count) Plug-ins von Apple ausgeblendet")
        }
    }

    public var findingCount: Int { all.count { $0.rating?.isFinding == true } }

    /// Keine fremde Erweiterung, und die Quelle wurde vollständig gelesen – nur dann ist die leere Liste eine Entwarnung.
    public var isCalm: Bool { all.isEmpty && coverage?.isComplete == true }

    /// Hinweis zur unvollständigen Prüfung (Liste nicht oder nur teilweise gelesen); `nil` bei vollständiger.
    public func notice(now: Date, calendar: Calendar = .current) -> String? {
        guard let coverage else { return String(localized: "Noch nicht geprüft – der erste Scan läuft.") }
        guard !coverage.isComplete else { return nil }
        return ([coverage.headline] + coverage.reasons(now: now, calendar: calendar)).joined(separator: ": ")
    }

    public func row(withID id: ExtensionRow.ID?) -> ExtensionRow? {
        id.flatMap { id in all.first { $0.id == id } }
    }

    public func detail(of row: ExtensionRow, calendar: Calendar = .current) -> ExtensionDetail {
        ExtensionDetail(row: row, calendar: calendar)
    }

    /// Zustandszeile: Zahl und Auffälliges als Urteil, Chips für Kern, Freigaben und Akzeptanz; Kenndaten mit
    /// ausgeblendeten Plug-ins und dem Stand der Prüfung.
    public func verdict(now: Date, calendar: Calendar = .current) -> ExtensionVerdict {
        let facts = ([Self.hiddenText(hiddenApplePlugins)] + [coverage?.timeText(now: now, calendar: calendar)])
            .compactMap(\.self).joined(separator: " · ")
        guard !all.isEmpty else {
            return isCalm
                ? ExtensionVerdict(title: String(localized: "Keine fremden Erweiterungen"), level: .calm,
                                   items: [ExtensionVerdict.Item(text: String(localized: "Kern frei"), tone: .positive)],
                                   facts: facts)
                : ExtensionVerdict(title: String(localized: "Nicht vollständig geprüft"), level: .calm, items: [],
                                   facts: facts)
        }
        let count = all.count == 1 ? String(localized: "1 Erweiterung") : String(localized: "\(all.count) Erweiterungen")
        let title = findingCount > 0 ? String(localized: "\(count), \(findingCount) auffällig") : count
        let level: SystemVerdict.Level = all.contains { $0.rating == .critical } ? .critical
            : findingCount > 0 ? .finding : .calm
        return ExtensionVerdict(title: title, level: level, items: verdictItems, facts: facts)
    }

    private var verdictItems: [ExtensionVerdict.Item] {
        let kernel = all.filter { $0.layer == .kernel }
        let kernelTone: ExtensionTone = kernel.contains { $0.rating == .critical } ? .critical
            : kernel.contains { $0.rating?.isFinding == true } ? .finding : .neutral
        let waiting = all.count { $0.record.state == .waitingForUser }
        let accepted = all.count { $0.rating == .accepted }
        return [
            kernel.isEmpty ? ExtensionVerdict.Item(text: String(localized: "Kern frei"), tone: .positive)
                : ExtensionVerdict.Item(text: String(localized: "\(kernel.count) im Kern"), tone: kernelTone),
            waiting == 0 ? nil : ExtensionVerdict.Item(
                text: waiting == 1 ? String(localized: "1 wartet auf Freigabe") : String(localized: "\(waiting) warten auf Freigabe"),
                tone: .info),
            accepted == 0 ? nil : ExtensionVerdict.Item(text: String(localized: "\(accepted) akzeptiert"), tone: .neutral),
        ].compactMap(\.self)
    }

    /// Ruhiges Urteil ohne fremde Erweiterungen.
    public static let calmTitle = String(localized: "Kein fremder Code mit Sonderrechten")
    public static let calmReason = String(localized: "Grantry hat keine Kernel-Erweiterung, keine Systemerweiterung, keinen Treiber und kein Plug-in anderer Hersteller gefunden.")
    public static let calmNote = String(localized: "Erweiterungen und Plug-ins von Apple gehören zu macOS; Grantry blendet sie aus.")

    /// Was Grantry für das ruhige Urteil geprüft hat, je Liste ein Satz.
    public var calmChecks: [String] {
        [
            String(localized: "Kernel-Erweiterungen: keine geladen, keine installiert"),
            String(localized: "Systemerweiterungen: keine aktiv, keine wartet auf Freigabe"),
            String(localized: "Treiber: keine"),
            hiddenApplePlugins > 0 ? String(localized: "Audio- und Video-Plug-ins: nur von Apple")
                : String(localized: "Audio- und Video-Plug-ins: keine"),
        ]
    }
}
