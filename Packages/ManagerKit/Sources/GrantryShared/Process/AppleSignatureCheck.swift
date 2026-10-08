import Foundation
import Security

/// Ob ein Programm von Apple signiert ist.
public enum AppleSignatureVerdict: Sendable, Equatable {
    case apple, notApple
    /// Nicht prüfbar (Datei fehlt, Prozess nicht greifbar, anderer Fehler).
    case unknown
}

public protocol AppleSignatureChecking: Sendable {
    func verdict(pid: pid_t, executablePath: String) -> AppleSignatureVerdict
}

/// Prüft „anchor apple“ am laufenden Code (`SecCodeCopyGuestWithAttributes` mit `kSecGuestAttributePid`,
/// `SecCodeCheckValidity`) und an der Datei (`SecStaticCodeCheckValidity`, nur Basisprüfung). Fail-closed
/// (`combine`): Apple gewinnt, „nicht Apple“ gilt nur, wenn beide Prüfungen eindeutig `errSecCSReqFailed` bzw.
/// `errSecCSUnsigned` melden. Interpreter wie `/usr/bin/python3` sind Apple-signiert und werden so abgelehnt.
public struct SecurityAppleSignatureCheck: AppleSignatureChecking {
    static let requirementText = "anchor apple"

    public init() {}

    public func verdict(pid: pid_t, executablePath: String) -> AppleSignatureVerdict {
        Self.combine(running: Self.runningVerdict(pid: pid), file: Self.fileVerdict(path: executablePath))
    }

    static func combine(running: AppleSignatureVerdict, file: AppleSignatureVerdict) -> AppleSignatureVerdict {
        if running == .apple || file == .apple { return .apple }
        return running == .notApple && file == .notApple ? .notApple : .unknown
    }

    static func verdict(for status: OSStatus) -> AppleSignatureVerdict {
        switch status {
        case errSecSuccess: .apple
        case errSecCSReqFailed, errSecCSUnsigned: .notApple
        default: .unknown
        }
    }

    static func runningVerdict(pid: pid_t) -> AppleSignatureVerdict {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              let requirement = requirement() else { return .unknown }
        return verdict(for: SecCodeCheckValidity(code, [], requirement))
    }

    static func fileVerdict(path: String) -> AppleSignatureVerdict {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              let requirement = requirement() else { return .unknown }
        return verdict(for: SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement))
    }

    private static func requirement() -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}
