import Foundation

/// Zählkachel der Übersicht (LB-3.2, #544; Spec 2026-11-10 § 11.3 a): die heutigen fünf Kacheln mit derselben Zahl und
/// demselben Sprung, im Lagebild mit kurzem Detail und Betonung statt Symbol und Farbe je Kachel.
public struct DashboardTile: Hashable, Sendable, Identifiable {
    /// Die Kachel; bestimmt in der Oberfläche den Sprung.
    public enum Kind: Hashable, Sendable, CaseIterable {
        case appsWithAccess, newEntries, flagged, security, exposed
    }

    /// Ton der Kachel: ohne Aussage, Neues, Befund, ruhig (nichts gefunden).
    public enum Emphasis: Hashable, Sendable {
        case plain, new, finding, calm
    }

    /// Was die Kacheln aus dem Scan lesen.
    public struct Facts: Hashable, Sendable {
        public var appsWithAccess: Int
        public var newEntries: Int
        public var criticalEntries: Int
        public var reviewEntries: Int
        /// Einträge, deren höchster Befund niedrig ist.
        public var hints: Int
        public var openSecurityChecks: Int
        /// Schlechteste Prüfung der Sicherheit; `nil` ohne Prüfungen.
        public var securityState: SecurityState?
        public var exposedServices: Int

        public init(appsWithAccess: Int = 0, newEntries: Int = 0, criticalEntries: Int = 0, reviewEntries: Int = 0,
                    hints: Int = 0, openSecurityChecks: Int = 0, securityState: SecurityState? = nil,
                    exposedServices: Int = 0) {
            self.appsWithAccess = appsWithAccess
            self.newEntries = newEntries
            self.criticalEntries = criticalEntries
            self.reviewEntries = reviewEntries
            self.hints = hints
            self.openSecurityChecks = openSecurityChecks
            self.securityState = securityState
            self.exposedServices = exposedServices
        }

        public init(_ presentation: PresentationSnapshot) {
            let metrics = presentation.metrics
            self.init(appsWithAccess: metrics.appsWithAccess, newEntries: metrics.newSince7Days,
                      criticalEntries: metrics.flagged.criticalCount,
                      reviewEntries: metrics.flaggedCount - metrics.flagged.criticalCount, hints: metrics.hintCount,
                      openSecurityChecks: presentation.security.hintCount,
                      securityState: presentation.security.worstState,
                      exposedServices: presentation.network.exposedCount)
        }
    }

    public let kind: Kind
    public let title: String
    public let value: Int
    public let detail: String
    public let emphasis: Emphasis

    public var id: Kind { kind }

    /// Die fünf Kacheln in der Reihenfolge der Übersicht.
    public static func tiles(_ facts: Facts) -> [DashboardTile] {
        let flagged = facts.criticalEntries + facts.reviewEntries
        return [
            DashboardTile(kind: .appsWithAccess, title: String(localized: "Apps mit Zugriff"),
                          value: facts.appsWithAccess, detail: String(localized: "mit mindestens einer Berechtigung"),
                          emphasis: .plain),
            DashboardTile(kind: .newEntries, title: String(localized: "Neu seit 7 Tagen"), value: facts.newEntries,
                          detail: String(localized: "Apps, Rechte, Autostart, Agenten"),
                          emphasis: facts.newEntries > 0 ? .new : .plain),
            DashboardTile(kind: .flagged, title: String(localized: "Auffällig"), value: flagged,
                          detail: flaggedDetail(facts), emphasis: flagged > 0 ? .finding : .calm),
            DashboardTile(kind: .security, title: String(localized: "Sicherheit"), value: facts.openSecurityChecks,
                          detail: securityDetail(facts), emphasis: securityEmphasis(facts)),
            DashboardTile(kind: .exposed, title: String(localized: "Aus dem Netz erreichbar"),
                          value: facts.exposedServices, detail: exposedDetail(facts.exposedServices),
                          emphasis: facts.exposedServices > 0 ? .finding : .calm),
        ]
    }

    /// „1 hoch · 1 mittel“, ohne auffällige Einträge „keine Befunde“ (samt Hinweisen).
    private static func flaggedDetail(_ facts: Facts) -> String {
        let parts = [
            facts.criticalEntries > 0 ? String(localized: "\(facts.criticalEntries) hoch") : nil,
            facts.reviewEntries > 0 ? String(localized: "\(facts.reviewEntries) mittel") : nil,
        ].compactMap(\.self)
        guard parts.isEmpty else { return parts.joined(separator: " · ") }
        let none = String(localized: "keine Befunde")
        switch facts.hints {
        case 0: return none
        case 1: return none + " · " + String(localized: "1 Hinweis")
        default: return none + " · " + String(localized: "\(facts.hints) Hinweise")
        }
    }

    private static func securityDetail(_ facts: Facts) -> String {
        switch (facts.openSecurityChecks, facts.securityState) {
        case (1, _): String(localized: "1 Punkt offen")
        case (let count, _) where count > 1: String(localized: "\(count) Punkte offen")
        case (_, .good?): String(localized: "alles geschützt")
        case (_, nil): String(localized: "noch nicht geprüft")
        default: String(localized: "nicht alle Prüfungen möglich")
        }
    }

    private static func securityEmphasis(_ facts: Facts) -> Emphasis {
        if facts.openSecurityChecks > 0 { return .finding }
        return facts.securityState == .good ? .calm : .plain
    }

    private static func exposedDetail(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "keine Dienste")
        case 1: String(localized: "Dienst nimmt Verbindungen an")
        default: String(localized: "Dienste nehmen Verbindungen an")
        }
    }
}
