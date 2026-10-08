/// Ein auffälliger Eintrag im Snapshot.
public struct RiskFinding: Identifiable, Hashable, Sendable, Codable {
    public enum Rule: String, Hashable, Sendable, Codable {
        case unsignedClient, orphan, sensitiveNonNotarized, unsignedProgram, invalidSignature
        case teamIDChanged, unsignedApp, intelOnly, symlinkedApp, specialFiles
        case exposedListener
        case unpinnedPackage, plaintextSecret, writableConfig, untrustedProgram, cleartextRemote, autoApproval
    }

    /// Schweregrad eines Findings; bestimmt die Sortierung in `RiskEvaluator.evaluate`.
    public enum Severity: Int, Comparable, Sendable, Codable {
        case low = 1, medium = 2, high = 3

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let rule: Rule
    public let severity: Severity
    /// `id` des betroffenen `PermissionGrant`, `AutostartItem`, `InstalledApp`, `NetworkListener`, `MCPServerEntry` bzw.
    /// `AgentAutoApproval`.
    public let recordID: String
    public let message: String

    /// `rule|recordID`: eindeutig, da dieselbe Aufzeichnung von mehreren Regeln geflaggt werden kann.
    public var id: String { "\(rule.rawValue)|\(recordID)" }

    public init(rule: Rule, severity: Severity, recordID: String, message: String) {
        self.rule = rule
        self.severity = severity
        self.recordID = recordID
        self.message = message
    }
}

/// Eine Prüfregel; neue Regeln werden als eigene Typen ergänzt.
public protocol RiskRule: Sendable {
    func evaluate(_ snapshot: Snapshot) -> [RiskFinding]
    /// Wie `evaluate(_:)`, zusätzlich mit den Ergebnissen der tiefen Signaturprüfung je Pfad (siehe
    /// `DeepSignatureVerifier`). Standard: `evaluate(_:)` – nur Regeln, die diese Ergebnisse brauchen, überschreiben es.
    func evaluate(_ snapshot: Snapshot, signatures: [String: DeepSignatureVerdict]) -> [RiskFinding]
}

extension RiskRule {
    public func evaluate(_ snapshot: Snapshot, signatures: [String: DeepSignatureVerdict]) -> [RiskFinding] {
        evaluate(snapshot)
    }
}

/// App ist unsigniert oder nur ad-hoc signiert.
public struct UnsignedClientRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        let grants = snapshot.grants
            .filter { $0.authValue.isGranted && Self.isUnsigned($0.client) }
            .map {
                RiskFinding(
                    rule: .unsignedClient, severity: .high, recordID: $0.id,
                    message: "\($0.client.displayName) ist nicht signiert"
                )
            }
        let items = snapshot.autostartItems.filter { $0.owner.map(Self.isUnsigned) ?? false }.map {
            RiskFinding(
                rule: .unsignedClient, severity: .high, recordID: $0.id,
                message: "Zugehörige App von \($0.label) ist nicht signiert"
            )
        }
        return grants + items
    }

    private static func isUnsigned(_ app: AppIdentity) -> Bool {
        app.signing.kind == .unsigned || app.signing.kind == .adHoc
    }
}

/// App bzw. Programm existiert nicht mehr.
///
/// Belegtes (`Presence.missing`) und vermutetes Fehlen (`probablyMissing`: weder Launch Services noch Spotlight
/// kennen die Bundle-ID) zählen, mit angepasster Meldung. `unknown` – root-only-Verzeichnis, nicht absoluter oder
/// unbekannter Programmpfad, Bundle-ID ohne Launch-Services-Eintrag – ist kein Fund. Apple-Komponenten
/// (`AppleComponent`) sind nie verwaist: Viele kennt Launch Services nicht, und das System verwaltet sie selbst.
///
/// Berechtigungen zählen nur, wenn sie erteilt sind (`AuthValue.isGranted`): Eine verweigerte Berechtigung einer
/// gelöschten App gewährt niemandem Zugriff – sie ist eine Altlast, kein Risiko. Solche Einträge kann die Oberfläche
/// (Plan 3c) als Aufräum-Hinweis anbieten.
public struct OrphanRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        let grants = snapshot.grants
            .filter { $0.authValue.isGranted }
            .filter { !AppleComponent.contains($0) }
            .compactMap { grant in
                Self.absence(of: grant.client.presence).map {
                    RiskFinding(
                        rule: .orphan, severity: .medium, recordID: grant.id,
                        message: "\(grant.client.displayName) ist \($0)"
                    )
                }
            }
        let items = snapshot.autostartItems
            .filter { $0.programPresence == .missing && !AppleComponent.contains($0) }
            .map {
                RiskFinding(
                    rule: .orphan, severity: .medium, recordID: $0.id,
                    message: "Programm von \($0.label) fehlt"
                )
            }
        return grants + items
    }

    /// Aussage der Meldung, `nil`, wenn kein Fehlen vorliegt.
    private static func absence(of presence: Presence) -> String? {
        switch presence {
        case .missing: "nicht mehr installiert"
        case .probablyMissing: "vermutlich nicht mehr installiert"
        case .present, .unknown: nil
        }
    }
}

/// Sensible Berechtigung ist einer App erlaubt, deren Notarisierung nicht bestätigt ist.
///
/// Gilt nur für `.developerID`- und `.unknown`-signierte, nachweislich vorhandene Apps: Apple- und App-Store-Apps
/// sind per Definition notarisiert, unsignierte bzw. ad-hoc-signierte Apps deckt bereits `UnsignedClientRule` ab,
/// nicht mehr vorhandene Apps (oft mit `.unknown`-Signing) deckt bereits `OrphanRule` ab – sonst gäbe es einen
/// Doppelalarm –, und bei unbekannter Existenz ließ sich die Signatur gar nicht prüfen. Apple-Komponenten
/// (`AppleComponent`) sind ausgenommen, auch wenn ihre Signatur nicht als `.apple` erkannt wurde.
/// `isNotarized == false` bei einer `.developerID`-App heißt oft nur, dass Gatekeeper sie auf diesem Mac noch nicht
/// geprüft hat (z. B. nach einem In-Place-Update) – daher niedrige Priorität statt Alarm.
///
/// `.development`-Builds sind ebenfalls ausgenommen: Mit einem Entwicklerzertifikat signierte Programme sind lokale
/// Builds (z. B. aus Xcode), laufen nur auf den registrierten Macs des Teams und werden nie notarisiert – der
/// Befund wäre bei jedem eigenen Debug-Build dauerhaft da, ohne etwas auszusagen.
public struct SensitiveNonNotarizedRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.grants
            .filter { $0.client.presence == .present && !AppleComponent.contains($0) }
            .filter { $0.authValue.isGranted }
            .filter { PermissionCatalog.service(for: $0.service).isSensitive }
            .filter { Self.notarizationUnconfirmed($0.client.signing) }
            .map {
                let service = PermissionCatalog.service(for: $0.service).displayName
                return RiskFinding(
                    rule: .sensitiveNonNotarized, severity: .low, recordID: $0.id,
                    message: "\($0.client.displayName) hat \(service), ist aber nicht als notarisiert bestätigt"
                )
            }
    }

    private static func notarizationUnconfirmed(_ signing: SigningInfo) -> Bool {
        (signing.kind == .developerID || signing.kind == .unknown) && !signing.isNotarized
    }
}

/// Wendet mehrere Regeln an.
public struct RiskEvaluator: Sendable {
    private let rules: [any RiskRule]

    public init(rules: [any RiskRule]) { self.rules = rules }

    public static let standard = RiskEvaluator(rules: [
        UnsignedClientRule(), OrphanRule(), SensitiveNonNotarizedRule(), UnsignedProgramRule(), InvalidSignatureRule(),
        TeamIDChangedRule(), UnsignedAppRule(), IntelOnlyRule(), SymlinkedAppRule(),
        ExposedListenerRule(),
        UnpinnedPackageRule(), PlaintextSecretRule(), WritableAgentConfigRule(), UntrustedMCPProgramRule(),
        CleartextRemoteRule(), ActiveAutoApprovalRule(),
    ])

    /// Findings aller Regeln, absteigend nach Schweregrad sortiert, bei Gleichstand aufsteigend nach `recordID`
    /// und zuletzt nach `rule` (deterministisch für die UI).
    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        evaluate(snapshot, signatures: [:])
    }

    /// Wie `evaluate(_:)`, mit den bisher bekannten Ergebnissen der tiefen Signaturprüfung je Pfad.
    public func evaluate(_ snapshot: Snapshot, signatures: [String: DeepSignatureVerdict]) -> [RiskFinding] {
        rules.flatMap { $0.evaluate(snapshot, signatures: signatures) }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                if lhs.recordID != rhs.recordID { return lhs.recordID < rhs.recordID }
                return lhs.rule.rawValue < rhs.rule.rawValue
            }
    }
}
