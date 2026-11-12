import Foundation

/// Urteil der Lagezeile in der Übersicht (LB-3.2, #544; Spec 2026-11-10 § 11 Entscheidung 4, § 11.3 b und c). Es gilt
/// die erste zutreffende Regel:
/// 1. „Noch nicht geprüft“ vor dem ersten Scan (Schildform offen, keine Chips),
/// 2. „N Punkte auffällig“ aus auffälligen Einträgen, offenen Punkten der Sicherheit und aus dem Netz erreichbaren
///    Diensten – dieselben Zahlen wie die Kacheln; Grund ist der schwerste Punkt,
/// 3. „Unvollständig geprüft“, wenn Quellen fehlen (Schildform offen, kein Bernstein),
/// 4. sonst „Ruhig“, neue Einträge nur als ruhiger Chip.
/// Höchstens drei Chips in der Reihenfolge kritisch, prüfen, aus dem Netz, neu, unvollständig; rechts Scanzeit und
/// Abdeckung. Nur aus vorhandenen Daten, keine neue Quelle.
public struct DashboardVerdict: Hashable, Sendable {
    /// Was die Regel aus dem Scan liest (`init(_:scannedAt:)` aus `PresentationSnapshot`).
    public struct Facts: Hashable, Sendable {
        /// Auffällige Einträge mit hohem Befund.
        public var criticalEntries: Int
        /// Auffällige Einträge mit mittlerem Befund.
        public var reviewEntries: Int
        /// Text des schwersten Befunds eines Eintrags (`RiskFinding.message`).
        public var leadingEntry: String?
        /// Prüfungen der Sicherheit mit Hinweis oder kritisch (Kachel „Sicherheit“).
        public var openSecurityChecks: Int
        /// Davon kritisch.
        public var criticalSecurityChecks: Int
        /// Kurzbefund der schwersten offenen Prüfung („SIP aus“).
        public var leadingSecurityCheck: String?
        /// Aus dem Netz erreichbare Dienste (Kachel „Aus dem Netz erreichbar“).
        public var exposedServices: Int
        /// Neue Einträge der letzten 7 Tage (Kachel „Neu seit 7 Tagen“).
        public var newEntries: Int
        /// Bereiche, die der letzte Scan nicht vollständig gelesen hat.
        public var incompleteAreas: Int
        /// Quellen, die dabei fehlen.
        public var missingSources: Int
        public var scannedAt: Date?

        public init(criticalEntries: Int = 0, reviewEntries: Int = 0, leadingEntry: String? = nil,
                    openSecurityChecks: Int = 0, criticalSecurityChecks: Int = 0, leadingSecurityCheck: String? = nil,
                    exposedServices: Int = 0, newEntries: Int = 0, incompleteAreas: Int = 0, missingSources: Int = 0,
                    scannedAt: Date?) {
            self.criticalEntries = criticalEntries
            self.reviewEntries = reviewEntries
            self.leadingEntry = leadingEntry
            self.openSecurityChecks = openSecurityChecks
            self.criticalSecurityChecks = criticalSecurityChecks
            self.leadingSecurityCheck = leadingSecurityCheck
            self.exposedServices = exposedServices
            self.newEntries = newEntries
            self.incompleteAreas = incompleteAreas
            self.missingSources = missingSources
            self.scannedAt = scannedAt
        }

        /// Dieselben Zahlen wie die Kacheln der Übersicht.
        public init(_ presentation: PresentationSnapshot, scannedAt: Date?) {
            let flagged = presentation.metrics.flagged
            let security = presentation.security
            let leadingCheck = security.checks.first { $0.state == .critical }
                ?? security.checks.first { $0.state == .warning }
            let incomplete = presentation.coverage.incomplete
            self.init(criticalEntries: flagged.criticalCount,
                      reviewEntries: flagged.flaggedCount - flagged.criticalCount,
                      leadingEntry: presentation.leadingFinding?.message,
                      openSecurityChecks: security.hintCount, criticalSecurityChecks: security.criticalCount,
                      leadingSecurityCheck: leadingCheck?.brief,
                      exposedServices: presentation.network.exposedCount,
                      newEntries: presentation.metrics.newSince7Days,
                      incompleteAreas: incomplete.count,
                      missingSources: incomplete.reduce(0) { $0 + max($1.gaps.count, 1) },
                      scannedAt: scannedAt)
        }

        var points: Int { criticalEntries + reviewEntries + openSecurityChecks + exposedServices }
    }

    static let maximumItems = 3

    public let title: String
    public let reason: String
    public let shield: VerdictShield
    public let items: [SystemVerdict.Item]
    public let facts: String

    /// Vor dem ersten Scan bzw. während er läuft.
    public static func notScanned(isScanning: Bool) -> DashboardVerdict {
        DashboardVerdict(
            title: String(localized: "Noch nicht geprüft"),
            reason: isScanning ? String(localized: "Der erste Scan läuft; das Urteil folgt, sobald er fertig ist.")
                : String(localized: "Ein Scan liest Apps, Berechtigungen, Autostart und Agenten ein."),
            shield: .open, items: [], facts: String(localized: "kein Scan seit dem Start"))
    }

    public init(_ presentation: PresentationSnapshot, scannedAt: Date?) {
        self.init(Facts(presentation, scannedAt: scannedAt))
    }

    public init(_ facts: Facts) {
        if facts.points > 0 {
            title = facts.points == 1 ? String(localized: "1 Punkt auffällig")
                : String(localized: "\(facts.points) Punkte auffällig")
            reason = Self.findingReason(facts)
            shield = .finding
        } else if facts.incompleteAreas > 0 {
            title = String(localized: "Unvollständig geprüft")
            reason = facts.incompleteAreas == 1
                ? String(localized: "Keine Befunde in dem, was gelesen wurde; ein Bereich ist nicht vollständig.")
                : String(localized: "Keine Befunde in dem, was gelesen wurde; \(facts.incompleteAreas) Bereiche sind nicht vollständig.")
            shield = .open
        } else {
            title = String(localized: "Ruhig")
            reason = String(localized: "Keine Befunde, nichts aus dem Netz erreichbar, alle Quellen gelesen.")
            shield = .calm
        }
        items = Self.items(facts)
        self.facts = Self.factsText(facts)
    }

    private init(title: String, reason: String, shield: VerdictShield, items: [SystemVerdict.Item], facts: String) {
        self.title = title
        self.reason = reason
        self.shield = shield
        self.items = items
        self.facts = facts
    }
}

// MARK: - Texte

extension DashboardVerdict {
    /// Was den Grund anführt: der schwerste Punkt (hoher Eintrag, kritische Prüfung, mittlerer Eintrag, offene Prüfung,
    /// erreichbarer Dienst).
    private enum Lead {
        case entry, security, network

        init(_ facts: Facts) {
            if facts.criticalEntries > 0 {
                self = .entry
            } else if facts.criticalSecurityChecks > 0 {
                self = .security
            } else if facts.reviewEntries > 0 {
                self = .entry
            } else {
                self = facts.openSecurityChecks > 0 ? .security : .network
            }
        }
    }

    /// „<schwerster Punkt>; dazu <übrige Punkte>.“
    private static func findingReason(_ facts: Facts) -> String {
        let lead = Lead(facts)
        let entries = facts.criticalEntries + facts.reviewEntries
        let leading: String
        var others: [String] = []
        switch lead {
        case .entry:
            leading = facts.leadingEntry.map(sentence) ?? entriesText(entries, further: false)
        case .security:
            leading = facts.leadingSecurityCheck.map { String(localized: "Sicherheit: \($0)") }
                ?? securityText(facts.openSecurityChecks)
        case .network:
            leading = facts.exposedServices == 1 ? String(localized: "Ein Dienst nimmt Verbindungen aus dem Netz an")
                : String(localized: "\(facts.exposedServices) Dienste nehmen Verbindungen aus dem Netz an")
        }
        let remainingEntries = lead == .entry ? entries - 1 : entries
        if remainingEntries > 0 { others.append(entriesText(remainingEntries, further: lead == .entry)) }
        if lead != .security, facts.openSecurityChecks > 0 { others.append(securityText(facts.openSecurityChecks)) }
        if lead != .network, facts.exposedServices > 0 { others.append(networkText(facts.exposedServices)) }
        guard !others.isEmpty else { return leading + "." }
        return String(localized: "\(leading); dazu \(enumeration(others)).")
    }

    /// „A, B und C“ wie die übrigen Aufzählungen der Oberfläche (unabhängig von der Region des Macs).
    private static func enumeration(_ parts: [String]) -> String {
        guard let last = parts.last, parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " " + String(localized: "und") + " " + last
    }

    /// Befundtext ohne Schlusspunkt, damit „; dazu …“ anschließen kann.
    private static func sentence(_ message: String) -> String {
        message.hasSuffix(".") ? String(message.dropLast()) : message
    }

    private static func entriesText(_ count: Int, further: Bool) -> String {
        switch (count, further) {
        case (1, true): String(localized: "ein weiterer auffälliger Eintrag")
        case (_, true): String(localized: "\(count) weitere auffällige Einträge")
        case (1, false): String(localized: "ein auffälliger Eintrag")
        case (_, false): String(localized: "\(count) auffällige Einträge")
        }
    }

    private static func securityText(_ count: Int) -> String {
        count == 1 ? String(localized: "ein offener Punkt der Sicherheit")
            : String(localized: "\(count) offene Punkte der Sicherheit")
    }

    private static func networkText(_ count: Int) -> String {
        count == 1 ? String(localized: "ein Dienst, der Verbindungen aus dem Netz annimmt")
            : String(localized: "\(count) Dienste, die Verbindungen aus dem Netz annehmen")
    }

    private static func items(_ facts: Facts) -> [SystemVerdict.Item] {
        let review = facts.reviewEntries + facts.openSecurityChecks
        let incomplete = facts.incompleteAreas == 1 ? String(localized: "1 Bereich unvollständig")
            : String(localized: "\(facts.incompleteAreas) Bereiche unvollständig")
        let candidates: [SystemVerdict.Item?] = [
            facts.criticalEntries > 0
                ? SystemVerdict.Item(text: String(localized: "\(facts.criticalEntries) kritisch"), tone: .critical) : nil,
            review > 0 ? SystemVerdict.Item(text: String(localized: "\(review) prüfen"), tone: .warning) : nil,
            facts.exposedServices > 0
                ? SystemVerdict.Item(text: String(localized: "\(facts.exposedServices) aus dem Netz"), tone: .warning)
                : nil,
            facts.newEntries > 0
                ? SystemVerdict.Item(text: String(localized: "\(facts.newEntries) neu seit 7 Tagen"), tone: .neutral)
                : nil,
            facts.incompleteAreas > 0 ? SystemVerdict.Item(text: incomplete, tone: .neutral) : nil,
        ]
        return Array(candidates.compactMap(\.self).prefix(maximumItems))
    }

    /// „Scan 14:32 · Abdeckung vollständig“ bzw. „… · 2 Quellen fehlen“.
    private static func factsText(_ facts: Facts) -> String {
        let coverage = switch facts.missingSources {
        case 0: String(localized: "Abdeckung vollständig")
        case 1: String(localized: "1 Quelle fehlt")
        default: String(localized: "\(facts.missingSources) Quellen fehlen")
        }
        guard let scannedAt = facts.scannedAt else { return coverage }
        return String(localized: "Scan \(scannedAt.formatted(date: .omitted, time: .shortened))") + " · " + coverage
    }
}
