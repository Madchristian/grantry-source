// Deutsche Texte der Sicherheitsbewertung von Erweiterungen (TM-13.4): je Art ein Satz, was sie darf, und die
// Meldungen der Regeln in `ExtensionRiskRules`.

import Foundation

extension ExtensionKind {
    /// Ein Satz, was eine Erweiterung dieser Art darf (Spec 2026-11-08 § 5.2). Unbekannte Arten teilen sich einen Satz,
    /// ihre Kennung stammt aus fremder Ausgabe.
    public var permissionText: String {
        switch self {
        case .kernelExtension:
            "Läuft im Kern von macOS mit uneingeschränktem Zugriff auf Speicher, Geräte und alle Prozesse; ein Fehler "
                + "kann den ganzen Mac abstürzen lassen."
        case .driver:
            "Steuert ein Gerät außerhalb des Kerns (DriverKit) und darf direkt mit dieser Hardware sprechen."
        case .network:
            "Darf Netzwerkverkehr filtern, umleiten oder als VPN tunneln und kann dabei die Verbindungen aller Apps sehen."
        case .endpointSecurity:
            "Sieht jeden Programmstart und jeden Dateizugriff aller Programme und darf manche davon blockieren."
        case .camera:
            "Stellt eine Kamera bereit, die alle Apps mit Kamerazugriff als Videoquelle nutzen können."
        case .otherSystemExtension:
            "Systemerweiterung einer Art, die Grantry nicht kennt; sie läuft mit Sonderrechten außerhalb des Kerns."
        case .audioPlugin:
            "Wird vom Audiodienst von macOS geladen und kann den Ton aller Apps empfangen, verändern oder umleiten."
        case .videoPlugin:
            "Wird von jeder App mit Kamerazugriff geladen und läuft dort mit deren Rechten; veraltete Technik (DAL)."
        }
    }
}

/// Meldungen der Regeln (`RiskFinding.message`), ohne Schlusspunkt wie die übrigen Regeln.
enum ExtensionTexts {
    /// Name, ersatzweise die Bundle-ID – einzeilig und gekürzt, denn beides stammt vom Hersteller.
    static func label(of record: ExtensionRecord) -> String {
        ExtensionText.name(record.name ?? record.bundleID)
    }

    static func kernel(_ record: ExtensionRecord, signing: SigningInfo.Kind?) -> String {
        switch signing {
        case .unsigned: "\(label(of: record)) läuft im Kern und ist nicht signiert"
        case .adHoc: "\(label(of: record)) läuft im Kern und ist nur ad hoc signiert"
        default: "\(label(of: record)) läuft im Kern – auf Apple Silicon nur mit reduzierter Sicherheit"
        }
    }

    /// Was die Erweiterung sieht, bei einem Befund mit dessen Grund.
    static func privileged(_ record: ExtensionRecord, concern: PrivilegedExtensionRule.Concern?) -> String {
        let reach = record.kind == .endpointSecurity ? "sieht alle Prozesse und Dateizugriffe" : "kann den Netzwerkverkehr sehen"
        let base = "\(label(of: record)) (\(record.kind.displayName)) \(reach)"
        return switch concern {
        case .missingApp: "\(base) – die zugehörige App fehlt"
        case .unverifiableSigning: "\(base) – Signatur nicht prüfbar"
        case nil: base
        }
    }

    static func leftover(_ record: ExtensionRecord) -> String {
        "\(label(of: record)) (\(record.kind.displayName)) gehört zu keiner installierten App mehr – ein Rest"
    }

    static func pluginSignature(_ record: ExtensionRecord, signing: SigningInfo.Kind) -> String {
        let statement = signing == .adHoc ? "nur ad hoc signiert" : "nicht signiert"
        return "\(label(of: record)) (\(record.kind.displayName)) ist \(statement)"
    }

    static func deprecatedPlugin(_ record: ExtensionRecord) -> String {
        "\(label(of: record)) ist ein Video-Plug-in in veralteter Technik (DAL)"
    }
}
