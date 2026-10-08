import Foundation

/// Bewertet Sicherheitsfakten zu einem Zeitpunkt (Spec v2 §2). Alle Schwellen stehen hier.
public struct SecurityPolicy: Sendable, Equatable {
    /// Alle Altersangaben zählen in Kalendertagen (`CalendarDays`) – wie die Anzeige.
    public var calendar: Calendar = .current
    /// XProtect gilt bis zu so vielen Tagen als aktuell (good) …
    public var xprotectCurrentDays = 14
    /// … und bis zu so vielen als leicht veraltet (warning); älter → critical.
    public var xprotectStaleDays = 30
    /// Letzte Updatesuche höchstens so viele Tage alt, sonst warning.
    public var updateCheckMaxDays = 7
    /// Ab so vielen Tagen ist ein ausstehendes Update critical.
    public var pendingUpdateCriticalDays = 14

    public static let standard = SecurityPolicy()

    public init() {}

    /// Abgeschaltet → critical; übrige abgeschaltete Schlüssel → warning.
    private static let criticalUpdateKeys: Set<SoftwareUpdateKey> = [.automaticCheckEnabled, .criticalUpdateInstall, .configDataInstall]

    public func evaluate(_ facts: SecurityFacts, now: Date) -> SecurityState {
        switch facts {
        case .fileVault(let status):
            switch status {
            case .on: .good
            case .encrypting, .decrypting, .pendingRestart: .warning
            case .off: .critical
            }
        case .firewall(let enabled, let stealthMode):
            !enabled ? .critical : stealthMode ? .good : .warning
        case .sip(let status):
            switch status {
            case .enabled: .good
            case .customConfiguration: .warning
            case .disabled: .critical
            }
        case .gatekeeper(let enabled):
            enabled ? .good : .critical
        case .xprotect(_, let installedAt):
            xprotectState(days: days(since: installedAt, now: now))
        case .automaticUpdates(let disabled):
            !disabled.isDisjoint(with: Self.criticalUpdateKeys) ? .critical : disabled.isEmpty ? .good : .warning
        case .pendingUpdates(let updates, let lastCheck):
            pendingUpdatesState(updates, lastCheck: lastCheck, now: now)
        case .mdmEnrollment:
            .good
        }
    }

    private func days(since date: Date, now: Date) -> Int {
        CalendarDays.since(date, now: now, calendar: calendar)
    }

    private func xprotectState(days: Int) -> SecurityState {
        if days <= xprotectCurrentDays { return .good }
        return days <= xprotectStaleDays ? .warning : .critical
    }

    /// Ältestes ausstehendes Update ≥ Schwelle → critical; sonst warning bei ausstehenden Updates, nie erfolgter oder
    /// zu alter Suche.
    private func pendingUpdatesState(_ updates: [PendingUpdate], lastCheck: Date?, now: Date) -> SecurityState {
        if let oldest = updates.map(\.firstSeenAt).min(), days(since: oldest, now: now) >= pendingUpdateCriticalDays {
            return .critical
        }
        guard updates.isEmpty, let lastCheck, days(since: lastCheck, now: now) <= updateCheckMaxDays else { return .warning }
        return .good
    }
}
