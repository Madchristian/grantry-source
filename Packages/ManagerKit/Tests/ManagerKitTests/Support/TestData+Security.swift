import Foundation
@testable import ManagerKit

extension TestData {
    static let firewallOn = SecurityFacts.firewall(enabled: true, stealthMode: true)
    static let stealthOff = SecurityFacts.firewall(enabled: true, stealthMode: false)
    static let firewallOff = SecurityFacts.firewall(enabled: false, stealthMode: false)

    static func securityCheck(_ facts: SecurityFacts, state: SecurityState) -> SecurityCheck {
        SecurityCheck(kind: facts.kind, state: state, facts: facts)
    }

    static func update(_ identifier: String, name: String = "macOS 27.0.1", firstSeenAt: Date = date) -> PendingUpdate {
        PendingUpdate(identifier: identifier, displayName: name, displayVersion: nil, firstSeenAt: firstSeenAt)
    }

    /// Alle zehn Prüfungen in Ordnung, in Anzeigereihenfolge.
    static func goodSecurityChecks(now: Date = date) -> [SecurityCheck] {
        [
            .fileVault(.on), .automaticLogin(enabled: false), firewallOn, .sharingServices(active: []), .sip(.enabled),
            .gatekeeper(enabled: true), .xprotect(version: "5321", installedAt: now - 3 * day),
            .automaticUpdates(disabled: []), .pendingUpdates(updates: [], lastCheck: now - day),
            .mdmEnrollment(enrolled: false, viaDEP: false),
        ].map { evaluatedCheck($0, now: now) }
    }

    /// Prüfung mit der Ampel, die die Standard-Policy zu `now` vergibt.
    static func evaluatedCheck(_ facts: SecurityFacts, now: Date = date) -> SecurityCheck {
        SecurityCheck(kind: facts.kind, state: SecurityPolicy.standard.evaluate(facts, now: now), facts: facts)
    }
}
