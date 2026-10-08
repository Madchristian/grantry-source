import Foundation
import GrantryShared

/// Unbekanntes Format einer Prüfungsausgabe (z. B. nach einem macOS-Update) → Prüfung `unknown`.
public enum SecurityParseError: LocalizedError, Equatable {
    case unexpectedOutput(command: String, output: String)
    case unreadablePreferences(path: String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedOutput(let command, let output):
            let excerpt = output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
            return "Unerwartete Ausgabe von \(command): " + (excerpt.isEmpty ? "(leer)" : "„\(excerpt)“")
        case .unreadablePreferences(let path):
            return "\(path) ist nicht lesbar oder keine Property-Liste"
        }
    }
}

/// Reine Parser der Befehlsausgaben (Fixtures: `Tests/ManagerKitTests/Fixtures/Security`). Werkzeuge antworten
/// unabhängig von der Systemsprache englisch.
enum SecurityParsers {
    static func fileVault(_ output: String) throws -> SecurityFacts {
        let lines = output.nonEmptyLines
        if lines.contains(where: { $0.hasPrefix("Encryption in progress") }) { return .fileVault(.encrypting) }
        if lines.contains(where: { $0.hasPrefix("Decryption in progress") }) { return .fileVault(.decrypting) }
        switch lines.first {
        case "FileVault is On."?: return .fileVault(.on)
        case "FileVault is Off."?: return .fileVault(.off)
        case let line? where line.hasPrefix("FileVault is Off, but will be enabled"): return .fileVault(.pendingRestart)
        default: throw SecurityParseError.unexpectedOutput(command: "fdesetup status", output: output)
        }
    }

    /// Auswertung gemeinsam mit dem Helper (`SocketFilterFirewallOutput`): `State = 1` (an) und `State = 2` (alle
    /// eingehenden blockieren) gelten beide als eingeschaltet.
    static func firewall(_ output: String) throws -> SecurityFacts {
        guard let enabled = SocketFilterFirewallOutput.isEnabled(in: output),
              let stealthMode = SocketFilterFirewallOutput.isStealthModeOn(in: output)
        else {
            throw SecurityParseError.unexpectedOutput(command: "socketfilterfw --getglobalstate --getstealthmode", output: output)
        }
        return .firewall(enabled: enabled, stealthMode: stealthMode)
    }

    /// Jede „Custom Configuration“ gilt als teilweise aktiv, unabhängig vom Wort davor (`enabled`/`unknown`).
    static func sip(_ output: String) throws -> SecurityFacts {
        let prefix = "System Integrity Protection status:"
        guard let line = output.nonEmptyLines.first(where: { $0.hasPrefix(prefix) }) else {
            throw SecurityParseError.unexpectedOutput(command: "csrutil status", output: output)
        }
        let status = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).lowercased()
        if status.contains("custom configuration") { return .sip(.customConfiguration) }
        if status.hasPrefix("enabled") { return .sip(.enabled) }
        if status.hasPrefix("disabled") { return .sip(.disabled) }
        throw SecurityParseError.unexpectedOutput(command: "csrutil status", output: output)
    }

    /// Auswertung gemeinsam mit dem Helper (`GatekeeperStatusOutput`).
    static func gatekeeper(_ output: String) throws -> SecurityFacts {
        guard let enabled = GatekeeperStatusOutput.isEnabled(in: output) else {
            throw SecurityParseError.unexpectedOutput(command: "spctl --status", output: output)
        }
        return .gatekeeper(enabled: enabled)
    }

    /// Ausgabe von `xprotect version --json`.
    static func xprotect(_ output: String) throws -> SecurityFacts {
        struct Version: Decodable {
            let version: String
            let installDate: String
            enum CodingKeys: String, CodingKey {
                case version = "xprotect_bundle_version"
                case installDate = "xprotect_bundle_install_date"
            }
        }
        guard let decoded = try? JSONDecoder().decode(Version.self, from: Data(output.utf8)),
              let installedAt = try? Date(decoded.installDate, strategy: .iso8601)
        else { throw SecurityParseError.unexpectedOutput(command: "xprotect version --json", output: output) }
        return .xprotect(version: decoded.version, installedAt: installedAt)
    }

    /// Nur „Yes…“ (etwa „Yes (User Approved)“) und „No“ sind bekannt; jeder andere Wert wirft, damit ein neuer Zustand
    /// (etwa „Pending“) keine Abmeldung vortäuscht. Fehlt die DEP-Zeile, gilt „nicht über DEP“.
    static func mdmEnrollment(_ output: String) throws -> SecurityFacts {
        let lines = output.nonEmptyLines
        let unexpected = SecurityParseError.unexpectedOutput(command: "profiles status -type enrollment", output: output)
        func value(of key: String) -> String? {
            lines.first { $0.hasPrefix(key + ":") }.map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
        }
        func answer(_ value: String) throws -> Bool {
            if value.hasPrefix("Yes") { return true }
            if value == "No" { return false }
            throw unexpected
        }
        guard let mdm = value(of: "MDM enrollment") else { throw unexpected }
        return .mdmEnrollment(enrolled: try answer(mdm), viaDEP: try value(of: "Enrolled via DEP").map(answer) ?? false)
    }
}

extension String {
    /// Zeilen ohne Rand-Leerraum, leere ausgelassen.
    fileprivate var nonEmptyLines: [String] {
        split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
