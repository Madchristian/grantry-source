import Foundation

/// Filter der Liste „Netzwerk“ (Spec §8). Systemdienste (`NetworkListener.isAppleService`) sind standardmäßig
/// ausgeblendet.
public struct NetworkListenerFilter: Hashable, Sendable {
    public var onlyExposed = false
    public var onlyNonApple = false
    public var onlyInterpreters = false
    public var onlyWithoutApp = false
    public var showsSystemServices = false

    public init() {}

    public var isActive: Bool { self != NetworkListenerFilter() }
}

/// Eine Zeile der Liste.
public struct NetworkListenerRow: Identifiable, Hashable, Sendable {
    public let listener: NetworkListener
    /// Name der zugehörigen App, sonst des Prozesses – nie der Eltern-App: Ein `python3` aus iTerm heißt `python3`.
    public let title: String
    /// Zugehörige App: äußerstes `.app`-Bundle im eigenen Programmpfad (`NetworkListenerPresenter.bundlePath(of:)`).
    public let bundlePath: String?
    /// App, aus der das Programm gestartet wurde (`NetworkListenerPresenter.launchingAppPath(of:)`), nur als Herkunft.
    public let launchingAppPath: String?
    public let severity: RiskFinding.Severity?

    /// Zeile zu `listener` – auch für das Detail eines Lauschers, der gerade nicht in der gefilterten Liste steht.
    public init(_ listener: NetworkListener, severity: RiskFinding.Severity? = nil) {
        let bundle = NetworkListenerPresenter.bundlePath(of: listener)
        self.listener = listener
        title = listener.program.title
        bundlePath = bundle
        launchingAppPath = NetworkListenerPresenter.launchingAppPath(of: listener)
        self.severity = severity
    }

    public var id: String { listener.id }
    /// Name der Eltern-App („iTerm“).
    public var launchingAppName: String? { launchingAppPath.map(NetworkProgram.appName(ofBundle:)) }
    /// „3000/tcp · alle Schnittstellen“, mit Eltern-App „… · gestartet aus iTerm“.
    public var subtitle: String {
        ([listener.portText, listener.reachabilityText] + (launchingAppName.map { ["gestartet aus \($0)"] } ?? []))
            .joined(separator: " · ")
    }
    public var isInterpreter: Bool { listener.program.isInterpreter }
}

/// Zeilen der Liste „Netzwerk“: Zuordnung zur App, Filter, Suche und Sortierung.
public enum NetworkListenerPresenter {
    /// Äußerstes `.app`-Bundle im eigenen Programmpfad; die Elternkette zählt nicht.
    public static func bundlePath(of listener: NetworkListener) -> String? {
        listener.program.bundlePath
    }

    /// Äußerstes `.app`-Bundle des nächsten Elternteils, das nicht im eigenen Bundle liegt („gestartet aus iTerm“).
    public static func launchingAppPath(of listener: NetworkListener) -> String? {
        let own = bundlePath(of: listener)
        return listener.ancestorPaths.lazy.compactMap(NetworkProgram.outermostBundle(in:)).first { $0 != own }
    }

    /// Gefilterte, durchsuchte Zeilen: von außen erreichbare zuerst, dann nach Name.
    /// - Parameter severity: höchster Schweregrad der Befunde zu einer Lauscher-ID.
    public static func rows(
        _ listeners: [NetworkListener], severity: (String) -> RiskFinding.Severity?, query: String,
        filter: NetworkListenerFilter
    ) -> [NetworkListenerRow] {
        listeners.map { NetworkListenerRow($0, severity: severity($0.id)) }
        .filter { matches($0, filter: filter) && matches($0, query: query) }
        .sorted { lhs, rhs in
            if lhs.listener.reachability.isExposed != rhs.listener.reachability.isExposed { return lhs.listener.reachability.isExposed }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    private static func matches(_ row: NetworkListenerRow, filter: NetworkListenerFilter) -> Bool {
        let isApple = row.listener.isAppleService
        return (filter.showsSystemServices || !isApple)
            && (!filter.onlyExposed || row.listener.isExposedService)
            && (!filter.onlyNonApple || !isApple)
            && (!filter.onlyInterpreters || row.isInterpreter)
            && (!filter.onlyWithoutApp || row.bundlePath == nil)
    }

    private static func matches(_ row: NetworkListenerRow, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return ([row.title, row.listener.executablePath, row.listener.portText] + [row.launchingAppName].compactMap(\.self))
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Hinweis zur Firewall im Bereich „Netzwerk“.
public enum NetworkFirewallHint: Hashable, Sendable {
    /// Firewall aus und `exposedCount` von außen erreichbare Lauscher, die keine Systemdienste sind.
    case firewallOff(exposedCount: Int)
    /// Firewall an, aber es gibt von außen erreichbare Lauscher: Signierte Apps können je nach Einstellung trotzdem
    /// eingehend erlaubt sein.
    case firewallOn
}

/// Alles, was der Bereich „Netzwerk“ und die Übersicht brauchen (ein Feld in `PresentationSnapshot`).
public struct NetworkOverview: Hashable, Sendable {
    public let listeners: [NetworkListener]
    /// Von außen erreichbare Lauscher, die weder Systemdienste noch vermutliche Clients sind
    /// (`NetworkListener.countsAsExposed`) – die Kachel „Von außen erreichbar“ schlüge sonst bei jedem Browser an. Die
    /// Liste zeigt solche Lauscher trotzdem, nur der Filter „Von außen erreichbar“ blendet sie wie die Kachel aus.
    public let exposedCount: Int
    public let firewallHint: NetworkFirewallHint?
    private let launchedByID: [String: AutostartItem]

    /// Autostart-Eintrag, der den Lauscher vermutlich startet; `nil`, wenn keiner passt. Nur bei gleichem Programm
    /// sicher – über das eigene Bundle oder die Eltern-App ist die Zuordnung eine Vermutung, die Oberfläche
    /// beschriftet sie entsprechend vorsichtig.
    public func launchedBy(_ listener: NetworkListener) -> AutostartItem? { launchedByID[listener.id] }

    public static let empty = NetworkOverview(listeners: [], exposedCount: 0, firewallHint: nil, launchedByID: [:])

    public static func make(snapshot: Snapshot) -> NetworkOverview {
        let exposed = snapshot.networkListeners.filter(\.countsAsExposed).count
        return NetworkOverview(
            listeners: snapshot.networkListeners,
            exposedCount: exposed,
            firewallHint: firewallHint(snapshot.securityChecks, exposedCount: exposed),
            launchedByID: launchedBy(snapshot)
        )
    }

    /// Nur aus einer aktuellen Prüfung: Bei `.unknown` sind die Fakten höchstens fortgeschrieben (wie `SecurityOverview`).
    /// Ohne erreichbare Lauscher gibt es nichts zu sagen – unabhängig vom Zustand der Firewall.
    private static func firewallHint(_ checks: [SecurityCheck], exposedCount: Int) -> NetworkFirewallHint? {
        guard exposedCount > 0, let check = checks.first(where: { $0.kind == .firewall }), check.state != .unknown,
              case .firewall(let enabled, _)? = check.facts else { return nil }
        return enabled ? .firewallOn : .firewallOff(exposedCount: exposedCount)
    }

    /// Autostart-Eintrag mit gleichem Programm, sonst einer, dessen Programm bzw. App im eigenen Bundle liegt, ohne
    /// eigenes Bundle in dem der Eltern-App.
    private static func launchedBy(_ snapshot: Snapshot) -> [String: AutostartItem] {
        var result: [String: AutostartItem] = [:]
        for listener in snapshot.networkListeners {
            let owner = NetworkListenerPresenter.bundlePath(of: listener)
                ?? NetworkListenerPresenter.launchingAppPath(of: listener)
            let match = snapshot.autostartItems.first { $0.program == listener.executablePath }
                ?? owner.flatMap { owner in
                    snapshot.autostartItems.first { item in
                        item.program.map { $0 == owner || $0.hasPrefix(owner + "/") } == true || item.owner?.path == owner
                    }
                }
            result[listener.id] = match
        }
        return result
    }
}
