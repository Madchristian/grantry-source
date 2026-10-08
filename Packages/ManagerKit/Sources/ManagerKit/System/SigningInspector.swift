import Foundation
import os
import Security

/// Prüft die Code-Signatur eines Pfads – App-Bundle oder einzelne ausführbare Datei.
public protocol SigningInspecting: Sendable {
    /// Ermittelt Signaturart, Team-ID und Notarisierung für `path`. Liefert `SigningInfo.unknown`, wenn der Pfad
    /// fehlt, kein prüfbares Code-Objekt ist, seine Signatur beschädigt ist oder die Prüfung nicht rechtzeitig endet.
    func inspect(path: String) -> SigningInfo
    /// Wie `inspect(path:)`, unterscheidet aber eine Zeitüberschreitung (`.timedOut`) vom echten Ergebnis – nur
    /// Letzteres dürfen Caches behalten. Standard: `inspect(path:)` gilt als abgeschlossen.
    func inspection(ofPath path: String) -> SigningInspection
}

extension SigningInspecting {
    public func inspection(ofPath path: String) -> SigningInspection {
        .completed(inspect(path: path))
    }
}

/// Ausgang einer Signaturprüfung (Review M1): ein Ergebnis – auch `.unknown` für eine beschädigte oder nicht
/// prüfbare Signatur – oder eine Zeitüberschreitung bzw. ein erschöpfter `BlockingCallGuard`. Eine
/// Zeitüberschreitung sagt nichts über die Signatur und wird nie gemerkt; der nächste Scan prüft erneut.
public enum SigningInspection: Hashable, Sendable {
    case completed(SigningInfo)
    case timedOut

    /// Das Ergebnis; nach einer Zeitüberschreitung `.unknown`.
    public var info: SigningInfo {
        switch self {
        case .completed(let info): info
        case .timedOut: .unknown
        }
    }

    /// `true` für ein Ergebnis, das sich bis zur nächsten Änderung des Ziels merken lässt.
    public var isConclusive: Bool { self != .timedOut }
}

/// Implementierung über Security.framework (`SecStaticCode`).
///
/// **Prüfumfang** (`kSecCSBasicValidateOnly`): Geprüft werden Code-Directory, CMS-Signatur und Zertifikatskette –
/// nicht die Hashes von Hauptprogramm und Ressourcen. Das Ergebnis beschreibt also Signierer und Signaturart, nicht
/// die geprüfte Unversehrtheit des Codes. Die Laufzeit liegt im einstelligen bis niedrigen zweistelligen ms-Bereich
/// pro Pfad. Zum Vergleich auf demselben Mac: vollständige Prüfung Xcode ≈ 120 s, Logic Pro ≈ 75 s,
/// Keynote ≈ 32 s; nur ohne Ressourcen (`kSecCSDoNotValidateResources`) Warp ≈ 0,9 s, Docker ≈ 0,6 s. Nachträglich
/// veränderter Code fällt dadurch nicht auf – das erzwingt Gatekeeper beim Start. Eine beschädigte Signatur wird
/// weiterhin erkannt (`errSecCSSignatureFailed`) und als `.unknown` gemeldet.
///
/// **Reihenfolge**: apple → appStore → developerID → development; ad-hoc wird vorher an den Signatur-Flags erkannt,
/// alles Übrige ist `.unknown`.
///
/// **Netzwerk**: `noNetworkAccess` unterbindet Sperrlistenabfragen. Die Anforderung `notarized` wird ohnehin nur lokal
/// beantwortet – über ein angeheftetes Ticket oder die Ticket-Datenbank von `syspolicyd`, die Gatekeeper bei der
/// Bewertung eines Programms füllt. Developer-ID-Programme ohne angeheftetes Ticket, die auf diesem Mac nie bewertet
/// wurden (z. B. per In-App-Update ersetzt), gelten daher als nicht notarisiert. Apple-Plattformcode und
/// App-Store-Apps erfüllen `notarized` nicht; sie gelten als notarisiert, weil Apple sie selbst prüft.
///
/// **Hänger**: Geprüft werden nur reguläre Dateien und Bundles mit regulärer `Info.plist` und regulärem Hauptprogramm
/// (`FileType.isSafeToInspect`); jede Prüfung läuft zusätzlich mit Zeitgrenze (`timeout`, `BlockingCallGuard.signing`)
/// und ergibt danach `.timedOut` bzw. `.unknown` („nicht prüfbar (Zeitüberschreitung)“ im Protokoll).
public struct SecuritySigningInspector: SigningInspecting {
    /// Frist je Prüfung – üblich sind Millisekunden.
    public static let defaultTimeout: Duration = .seconds(10)
    static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "signing")

    private let timeout: Duration
    private let callGuard: BlockingCallGuard

    public init() {
        self.init(timeout: Self.defaultTimeout)
    }

    init(timeout: Duration, callGuard: BlockingCallGuard = .signing) {
        self.timeout = timeout
        self.callGuard = callGuard
    }

    /// Anforderungen in der Requirement Language von Security.framework.
    private enum Requirement: String {
        /// Von Apple selbst signiert (Betriebssystem, Plattform-Binaries).
        case apple = "anchor apple"
        /// App Store: Leaf-Zertifikat „Apple Mac OS Application Signing“ (…6.1.9) oder „Apple iPhone OS Application
        /// Signing“ (…6.1.3) für iOS-/iPadOS-Apps, die auf Apple Silicon als Wrapper-Bundle (`Wrapper/*.app`) laufen.
        case appStore = "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate leaf[field.1.2.840.113635.100.6.1.3] exists)"
        /// Developer ID Application (Intermediate „Developer ID CA“ und passendes Leaf-Zertifikat).
        case developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        /// Apple Development bzw. Mac Developer: Intermediate „Apple Worldwide Developer Relations“ (…6.2.1) und ein
        /// Leaf-Zertifikat für Mac-Entwicklung (…6.1.12). Das vereinheitlichte „Apple Development“-Zertifikat trägt
        /// zusätzlich …6.1.2 (iPhone Developer); ältere reine iOS-Entwicklerzertifikate nur dieses.
        case development = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and (certificate leaf[field.1.2.840.113635.100.6.1.12] exists or certificate leaf[field.1.2.840.113635.100.6.1.2] exists)"
        /// Notarisierungsticket angeheftet oder in der lokalen Ticket-Datenbank bekannt (keine Online-Abfrage).
        case notarized = "notarized"
    }

    private static let validationFlags = SecCSFlags(rawValue: kSecCSBasicValidateOnly).union(.noNetworkAccess)

    public func inspect(path: String) -> SigningInfo {
        inspection(ofPath: path).info
    }

    public func inspection(ofPath path: String) -> SigningInspection {
        guard let info = callGuard.run(timeout: timeout, { Self.inspectWithoutTimeLimit(path: path) }) else {
            Self.logger.error("Signatur von \(PathDisplay.abbreviatingHome(path), privacy: .public) nicht prüfbar (Zeitüberschreitung)")
            return .timedOut
        }
        return .completed(info)
    }

    private static func inspectWithoutTimeLimit(path: String) -> SigningInfo {
        guard let code = staticCode(at: path) else { return .unknown }
        switch SecStaticCodeCheckValidity(code, Self.validationFlags, nil) {
        case errSecSuccess: break
        case errSecCSUnsigned: return SigningInfo(kind: .unsigned)
        default: return .unknown
        }

        let info = Self.signingInformation(of: code)
        let flags = SecCodeSignatureFlags(rawValue: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0)
        if flags.contains(.adhoc) { return SigningInfo(kind: .adHoc) }

        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        if Self.satisfies(code, .apple) { return SigningInfo(kind: .apple, teamID: teamID, isNotarized: true) }
        if Self.satisfies(code, .appStore) { return SigningInfo(kind: .appStore, teamID: teamID, isNotarized: true) }
        if Self.satisfies(code, .developerID) {
            return SigningInfo(kind: .developerID, teamID: teamID, isNotarized: Self.satisfies(code, .notarized),
                               developerName: Self.developerName(in: info, teamID: teamID))
        }
        if Self.satisfies(code, .development) {
            return SigningInfo(kind: .development, teamID: teamID, developerName: Self.developerName(in: info, teamID: teamID))
        }
        return SigningInfo(kind: .unknown, teamID: teamID, isNotarized: Self.satisfies(code, .notarized))
    }

    /// Code-Objekt für `path`; `nil` bei fehlendem Pfad, bei Sonderdateien (FIFO, Socket, Gerät – auch als
    /// `Info.plist` oder Hauptprogramm eines Bundles; das Öffnen könnte blockieren, siehe `FileType`) oder wenn kein
    /// Bundle bzw. keine ausführbare Datei erkannt wird.
    static func staticCode(at path: String) -> SecStaticCode? {
        guard FileType.isSafeToInspect(atPath: path) else { return nil }
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        return status == errSecSuccess ? code : nil
    }

    private static func signingInformation(of code: SecStaticCode) -> [String: Any] {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        return status == errSecSuccess ? (info as? [String: Any] ?? [:]) : [:]
    }

    /// Entwicklername aus dem Blattzertifikat (erstes Element von `kSecCodeInfoCertificates`).
    private static func developerName(in info: [String: Any], teamID: String?) -> String? {
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return nil }
        return SigningInfo.developerName(fromCertificateSummary: summary, teamID: teamID)
    }

    private static func satisfies(_ code: SecStaticCode, _ requirement: Requirement) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement.rawValue as CFString, [], &compiled) == errSecSuccess,
              let compiled else { return false }
        return SecStaticCodeCheckValidity(code, validationFlags, compiled) == errSecSuccess
    }
}
