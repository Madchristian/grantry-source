import Foundation

/// Bereich des Tabs „Dienste“ (Spec 2026-11-06 §6, Stufe 4).
public enum ServiceScope: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Eigene LaunchAgents, die Grantry starten und stoppen darf.
    case own
    /// Alle Dienste der grafischen Sitzung (`gui/<uid>`).
    case session
    /// Dienste der Domäne `system`, nur Anzeige.
    case system

    public var id: Self { self }

    public var title: String {
        switch self {
        case .own: "Eigene"
        case .session: "Sitzung"
        case .system: "System"
        }
    }

    func contains(_ row: ServiceRow) -> Bool {
        switch self {
        case .own: row.isControllable
        case .session: !row.domain.isSystem
        case .system: row.domain.isSystem
        }
    }
}

/// Zustand eines Dienstes in Anzeige und Farbe.
public enum ServiceState: Hashable, Sendable, CaseIterable {
    case running, idle, ended, failed

    public var title: String {
        switch self {
        case .running: "Läuft"
        case .idle: "Bereit"
        case .ended: "Beendet"
        case .failed: "Fehler"
        }
    }
}

/// Ein Dienst im Tab „Dienste“ mit dem zugehörigen Autostart-Eintrag des letzten Scans.
public struct ServiceRow: Hashable, Sendable, Identifiable {
    public let domain: LaunchdServiceDomain
    public let status: LaunchdServiceStatus
    /// Eintrag mit demselben Label in dieser Domäne; `nil` ohne Plist im Inventar (z. B. Apple-Dienste) oder wenn
    /// mehrere Plists das Label tragen.
    public let autostartItem: AutostartItem?
    /// Ob Starten und Stoppen angeboten wird (`ActionPolicy.serviceControlAvailability(for:)`).
    public let controlAvailability: ActionAvailability

    public init(domain: LaunchdServiceDomain, status: LaunchdServiceStatus, autostartItem: AutostartItem?,
                controlAvailability: ActionAvailability) {
        self.domain = domain
        self.status = status
        self.autostartItem = autostartItem
        self.controlAvailability = controlAvailability
    }

    public var id: String { "\(domain.name)/\(status.label)" }
    public var label: String { status.label }
    public var isRunning: Bool { status.pid != nil }
    public var isControllable: Bool { controlAvailability == .available }

    /// Warum Starten und Stoppen fehlen; `nil`, wenn sie angeboten werden.
    public var controlNote: String? {
        if case .readOnly(let reason) = controlAvailability { reason.description } else { nil }
    }

    /// Beendet mit SIGTERM (etwa nach „Stoppen“) gilt als regulär, andere Signale und Exit-Codes als Fehler.
    public var state: ServiceState {
        if isRunning { return .running }
        switch status.lastExit {
        case .never: return .idle
        case .exited(let code): return code == 0 ? .ended : .failed
        case .signaled(let signal): return signal == SIGTERM ? .ended : .failed
        case .other: return .ended
        }
    }

    public var pidText: String { status.pid.map { String($0) } ?? "–" }

    /// „0“, „78“, „Signal 9“ oder die Angabe von launchd; „–“, solange nie beendet.
    public var exitText: String {
        switch status.lastExit {
        case .never: "–"
        case .exited(let code): String(code)
        case .signaled(let signal): "Signal \(signal)"
        case .other(let text): text
        }
    }

    /// Plist des Autostart-Eintrags, Benutzerordner als „~“.
    public var plistText: String? { autostartItem?.plistPath.map { PathDisplay.abbreviatingHome($0) } }
}

/// Bedienzustand des Tabs „Dienste“.
public struct ServiceListOptions: Hashable, Sendable {
    public var scope = ServiceScope.session
    public var query = ""

    public init() {}
}

public struct ServiceListPresentation: Hashable, Sendable {
    public let rows: [ServiceRow]
    /// Dienste je Bereich, ohne Suche.
    public let counts: [ServiceScope: Int]
    /// Meldungen nicht lesbarer Domänen.
    public let failures: [String]

    public static let empty = ServiceListPresentation(rows: [], counts: [:], failures: [])

    public var runningCount: Int { rows.filter(\.isRunning).count }

    public var stateCounts: [ServiceState: Int] { Dictionary(grouping: rows, by: \.state).mapValues(\.count) }
}

/// Baut die Zeilen des Tabs „Dienste“. Rein; die Oberfläche ruft es nach jedem Lesen mit dem neuen Stand auf.
public enum ServiceListPresenter {
    /// Verknüpft die Dienste mit den Autostart-Einträgen des letzten Scans: LaunchAgents gehören zu `gui/<uid>`,
    /// LaunchDaemons zu `system`. Tragen mehrere Plists einer Domäne dasselbe Label, bleibt der Dienst ohne Eintrag –
    /// welche geladen ist, klärt erst `LaunchdServiceProbe` beim Steuern (wie `AutostartActions`).
    public static func rows(
        _ listings: [LaunchdServiceDomain: [LaunchdServiceStatus]], autostartItems: [AutostartItem],
        policy: ActionPolicy = ActionPolicy()
    ) -> [ServiceRow] {
        rows(listings, autostartItems: autostartItems, policy: policy, volumes: MountedVolume.current())
    }

    /// Die Einhängepunkte liest der Aufrufer einmal für alle Zeilen (die Oberfläche baut sie bei jedem Zeichnen neu).
    static func rows(
        _ listings: [LaunchdServiceDomain: [LaunchdServiceStatus]], autostartItems: [AutostartItem], policy: ActionPolicy,
        volumes: [MountedVolume]
    ) -> [ServiceRow] {
        let launchd = autostartItems.filter { $0.source == .launchd }
        let agents = byUniqueLabel(launchd.filter { $0.kind == .launchAgent })
        let daemons = byUniqueLabel(launchd.filter { $0.kind == .launchDaemon })
        return listings.keys.sorted { !$0.isSystem && $1.isSystem }.flatMap { domain in
            (listings[domain] ?? []).map { status in
                let item = (domain.isSystem ? daemons : agents)[status.label]
                let availability: ActionAvailability = if domain.isSystem {
                    .readOnly(.notOwnAgent)
                } else {
                    item.map { policy.serviceControlAvailability(for: $0, volumes: volumes) } ?? .readOnly(.noPlist)
                }
                return ServiceRow(domain: domain, status: status, autostartItem: item, controlAvailability: availability)
            }
        }
    }

    /// Bereich, Suche nach Label oder PID-Anfang; laufende Dienste zuerst, dann nach Label.
    public static func present(_ rows: [ServiceRow], options: ServiceListOptions,
                               failures: [String] = []) -> ServiceListPresentation {
        let counts = Dictionary(uniqueKeysWithValues: ServiceScope.allCases.map { scope in
            (scope, rows.filter(scope.contains).count)
        })
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = rows.filter { options.scope.contains($0) && (query.isEmpty || matches($0, query)) }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                let order = lhs.label.localizedStandardCompare(rhs.label)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        return ServiceListPresentation(rows: shown, counts: counts, failures: failures)
    }

    static func matches(_ row: ServiceRow, _ query: String) -> Bool {
        row.label.localizedCaseInsensitiveContains(query) || row.status.pid.map { String($0).hasPrefix(query) } == true
    }

    private static func byUniqueLabel(_ items: [AutostartItem]) -> [String: AutostartItem] {
        Dictionary(grouping: items, by: \.label).compactMapValues { $0.count == 1 ? $0[0] : nil }
    }
}
