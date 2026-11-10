import Foundation

// Sicherheitsbewertung der Erweiterungen (Spec 2026-11-08 § 5.2, TM-13.4). Schweregrade wie bei den übrigen Regeln:
// **niedrig** ist ein Hinweis, **mittel** ein Befund, **hoch** kritisch. Ohne Bewertung bleiben Erweiterungen, die beim
// nächsten Neustart entfernt werden (schon deinstalliert), und nachweislich von Apple signierte (Plug-ins; Apple-eigene
// Kernel-Erweiterungen erfasst die Quelle gar nicht). Wie überall gilt: kein Beleg, kein Befund – eine nicht lesbare oder
// nicht rechtzeitig geprüfte Signatur und eine unklare Zuordnung zur App melden nichts.
//
// Systemerweiterungen prüft Grantry nicht selbst: `systemextensionsctl` nennt keinen Pfad, und macOS prüft die Signatur
// bei der Aktivierung. Maßgeblich ist das Team, das macOS meldet; fehlt es, ist die Signatur nicht prüfbar.

/// Geladene Kernel-Erweiterung eines Drittanbieters (**mittel**): Sie läuft im Kern, auf Apple Silicon nur nach
/// Herabsetzen der Sicherheit. Unsigniert oder nur ad hoc signiert **hoch**. Apple-eigene erfasst die Quelle gar nicht
/// (`AppleKernelExtensionFilter`); installierte, aber nicht geladene bewertet höchstens `ExtensionLeftoverRule`.
public struct KernelExtensionRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.assessedExtensions.filter { $0.kind == .kernelExtension && $0.state == .loaded }.map { record in
            let signing = record.conclusiveSigningKind
            let isCritical = signing == .unsigned || signing == .adHoc
            return RiskFinding(
                rule: .kernelExtension, severity: isCritical ? .high : .medium, recordID: record.id,
                message: ExtensionTexts.kernel(record, signing: signing)
            )
        }
    }
}

/// Endpoint Security und Netzwerkerweiterungen sehen alle Prozesse bzw. den Netzwerkverkehr: ein Hinweis (**niedrig**).
/// Ein Befund (**mittel**), wenn die zugehörige App nachweislich fehlt oder die Signatur nicht prüfbar ist – macOS nennt
/// dann kein Team (etwa im Entwicklermodus von `systemextensionsctl`).
///
/// **Grenze:** `systemextensionsctl` unterscheidet Inhaltsfilter, VPN und DNS-Proxy nicht; alle Netzwerkerweiterungen
/// gelten daher als Inhaltsfilter.
public struct PrivilegedExtensionRule: RiskRule {
    /// Grund für den Befund.
    enum Concern {
        case missingApp, unverifiableSigning
    }

    static let kinds: Set<ExtensionKind> = [.endpointSecurity, .network]

    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.assessedExtensions.filter { Self.kinds.contains($0.kind) }.map { record in
            let concern = Self.concern(record)
            return RiskFinding(
                rule: .privilegedExtension, severity: concern == nil ? .low : .medium, recordID: record.id,
                message: ExtensionTexts.privileged(record, concern: concern)
            )
        }
    }

    static func concern(_ record: ExtensionRecord) -> Concern? {
        if record.owner == .missing { return .missingApp }
        return record.teamID == nil ? .unverifiableSigning : nil
    }
}

/// Erweiterung, zu der keine installierte App mehr gehört (**niedrig**): ein Rest, den der Hersteller nicht entfernt
/// hat. Nur bei belegtem Fehlen (`ExtensionOwnership.missing`), nicht bei unklarer Zuordnung. Endpoint Security und
/// Netzwerk meldet `PrivilegedExtensionRule` dann schon als Befund – sonst gäbe es einen Doppelalarm.
public struct ExtensionLeftoverRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.assessedExtensions
            .filter { $0.owner == .missing && !PrivilegedExtensionRule.kinds.contains($0.kind) }
            .map { RiskFinding(rule: .extensionLeftover, severity: .low, recordID: $0.id, message: ExtensionTexts.leftover($0)) }
    }
}

/// Plug-in in einem Systemdienst ohne gültige Signatur (**mittel**): nicht oder nur ad hoc signiert. Der Dienst lädt es
/// trotzdem und führt es mit seinen Rechten aus.
public struct ServicePluginSignatureRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.assessedExtensions.filter { $0.layer == .servicePlugin }.compactMap { record in
            guard let signing = record.conclusiveSigningKind, signing == .unsigned || signing == .adHoc else { return nil }
            return RiskFinding(
                rule: .pluginSignature, severity: .medium, recordID: record.id,
                message: ExtensionTexts.pluginSignature(record, signing: signing)
            )
        }
    }
}

/// Video-Plug-in (CoreMediaIO-DAL, **niedrig**): veraltete Technik, die Apple durch Kamera-Systemerweiterungen ersetzt.
public struct DeprecatedPluginRule: RiskRule {
    public init() {}

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.assessedExtensions.filter { $0.kind == .videoPlugin }.map {
            RiskFinding(rule: .deprecatedPlugin, severity: .low, recordID: $0.id, message: ExtensionTexts.deprecatedPlugin($0))
        }
    }
}

extension Snapshot {
    /// Erweiterungen, die die Regeln bewerten: ohne die, die beim nächsten Neustart entfernt werden, und ohne
    /// Apple-signierte.
    fileprivate var assessedExtensions: [ExtensionRecord] {
        extensions.filter { $0.state != .removalPending && $0.conclusiveSigningKind != .apple }
    }
}

extension ExtensionRecord {
    /// Signaturart, wenn die Prüfung rechtzeitig endete und etwas ergab; sonst `nil`.
    var conclusiveSigningKind: SigningInfo.Kind? {
        guard isSigningConclusive, let kind = signing?.kind, kind != .unknown else { return nil }
        return kind
    }
}
