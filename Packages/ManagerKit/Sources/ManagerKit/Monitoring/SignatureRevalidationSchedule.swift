import Foundation

/// Plan der verteilten Komplettprüfung der Code-Bäume (#649, Variante B): Statt alle Bäume im Intervall-Vollscan am
/// Stück zu traversieren (`DeepSignatureRevalidation.completeTree`), prüft die `MonitoringEngine` je Schritt einen
/// kleinen Block von Bäumen vollständig, gleichmäßig über `period` verteilt.
///
/// **Zusage:** Jeder Baum ist spätestens `maximumAge` nach Beginn seiner letzten Komplettprüfung erneut komplett
/// geprüft – unabhängig von Vollscans. Der Plan beginnt jeden Schritt mit dem Baum der frühesten Frist (letzte
/// Komplettprüfung plus `period`) und hält zugleich einen Abstand von `period / Zahl der Bäume` je geprüftem Baum ein,
/// sodass jeder Baum einmal je `period` drankommt und gleich alte Bäume (nach Start oder manuellem Scan) sich über die
/// Periode verteilen. `reserve = maximumAge - period` fängt Verzögerungen auf (Queue, gedrosselte Bäume, Zeitgeber im
/// Hintergrund). Überfällige Bäume – etwa nach dem Ruhezustand des Macs – folgen im Abstand von `catchUpPause`,
/// ältester zuerst.
///
/// **Blöcke:** Ein Schritt prüft nach dem fälligen Baum weitere in Fristreihenfolge (`dueOrder`), solange er unter
/// `blockBudget` bleibt; der nächste Schritt rückt um ebenso viele Abstände weiter. Gemessen kosteten dieselben
/// Prüfungen einzeln mit Pausen gedrosselt rund 30 % mehr CPU-Zeit als am Stück, in Blöcken zu etwa acht Bäumen nur
/// noch 5 bis 10 % (kalte Kerne und Caches je Block, siehe `docs/performance/issue-649-verteilte-revalidierung.md`).
///
/// Rein rechnerisch, ohne Zeitgeber: Die Engine fragt `nextStep`, wartet bis zu dessen Zeitpunkt und fragt danach erneut.
public struct SignatureRevalidationSchedule: Sendable, Equatable {
    /// Höchstes Alter der letzten Komplettprüfung eines Baums (Zusage, wie bisher das Intervall des Vollscans).
    public var maximumAge: TimeInterval
    /// Puffer vor `maximumAge`; der Plan zielt auf `period = maximumAge - reserve`. Jede Sekunde Puffer zieht die
    /// Prüfungen vor und kostet anteilig CPU-Zeit.
    public var reserve: TimeInterval
    /// Höchster Abstand zweier Schritte, wenn Bäume überfällig sind (Nachholen nach dem Aufwachen).
    public var catchUpPause: TimeInterval
    /// Ein Baum ohne Komplettprüfung, den der Plan schon angestoßen hat (etwa weil er sich während der Prüfung
    /// änderte), kommt frühestens so lange danach erneut – keine Schleife bei einem Bundle, das sich laufend ändert.
    public var retryPause: TimeInterval
    /// Wanduhr-Zeit, bis zu der ein Schritt nach dem fälligen Baum weitere Bäume prüft; `0`: genau einen.
    public var blockBudget: TimeInterval

    public init(maximumAge: TimeInterval = 900, reserve: TimeInterval = 30, catchUpPause: TimeInterval = 1,
                retryPause: TimeInterval = 60, blockBudget: TimeInterval = 1) {
        self.maximumAge = maximumAge
        self.reserve = reserve
        self.catchUpPause = catchUpPause
        self.retryPause = retryPause
        self.blockBudget = blockBudget
    }

    /// Zielabstand zweier Komplettprüfungen desselben Baums.
    public var period: TimeInterval { maximumAge - reserve }

    /// Der nächste vollständig zu prüfende Baum und wann.
    public struct Step: Equatable, Sendable {
        public let path: String
        public let date: Date

        public init(path: String, date: Date) {
            self.path = path
            self.date = date
        }
    }

    /// Abstand zweier Schritte bei `count` Bäumen.
    public func gap(forTargetCount count: Int) -> TimeInterval {
        period / Double(max(count, 1))
    }

    /// Nächster Schritt für `targets`, `nil` ohne Ziele: der Baum mit der frühesten Frist (`dueOrder`) und wann.
    ///
    /// - Parameters:
    ///   - targets: planbare Ziele, am längsten nicht vom Plan besuchte zuerst – das entscheidet bei gleicher Frist.
    ///   - completedAt: Beginn der letzten Komplettprüfung je Baum (aus `DeepSignatureVerifier.completeCheckAges`).
    ///   - attemptedAt: Wann der Plan Bäume ohne Komplettprüfung zuletzt angestoßen hat.
    ///   - previousStep: Zeitpunkt des vorigen Schritts (beim Start der Planung: der Start).
    ///   - previousBlockSize: Zahl der Bäume, die der vorige Schritt geprüft hat.
    public func nextStep(
        targets: [String], completedAt: [String: Date], attemptedAt: [String: Date], previousStep: Date,
        previousBlockSize: Int = 1, now: Date
    ) -> Step? {
        guard let earliest = dueDates(targets, completedAt: completedAt, attemptedAt: attemptedAt, now: now).first
        else { return nil }
        // Nach einer Zeitumstellung zurück läge der vorige Schritt in der Zukunft; der Plan wartet nie länger als die
        // Abstände des vorigen Blocks.
        let previous = min(previousStep, now)
        let gap = gap(forTargetCount: targets.count)
        let date = max(previous.addingTimeInterval(min(catchUpPause, gap)),
                       min(earliest.due, previous.addingTimeInterval(gap * Double(max(previousBlockSize, 1)))))
        return Step(path: earliest.path, date: date)
    }

    /// `targets` nach Frist, früheste zuerst; bei gleicher Frist in ihrer Reihenfolge. Ein Schritt prüft von vorn.
    public func dueOrder(
        _ targets: [String], completedAt: [String: Date], attemptedAt: [String: Date], now: Date
    ) -> [String] {
        dueDates(targets, completedAt: completedAt, attemptedAt: attemptedAt, now: now).map(\.path)
    }

    /// Frist je Ziel, früheste zuerst (stabil). Ein Prüfzeitpunkt in der Zukunft (Uhr zurückgestellt) ist nicht
    /// belastbar und sofort fällig; ein solcher Versuch zählt als eben.
    private func dueDates(
        _ targets: [String], completedAt: [String: Date], attemptedAt: [String: Date], now: Date
    ) -> [(path: String, due: Date)] {
        targets.enumerated().map { index, target in
            let due: Date
            if let completed = completedAt[target] {
                due = completed <= now ? completed.addingTimeInterval(period) : .distantPast
            } else {
                due = attemptedAt[target].map { min($0, now).addingTimeInterval(retryPause) } ?? .distantPast
            }
            return (index, target, due)
        }
        .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
        .map { (path: $0.1, due: $0.2) }
    }

    /// Bäume, deren letzte Komplettprüfung länger als `maximumAge` zurückliegt, fehlt oder nach einer Zeitumstellung in
    /// der Zukunft liegt: Ihr Ergebnis gilt nicht als aktuell geprüft.
    public func overdueTargets(_ targets: [String], completedAt: [String: Date], now: Date) -> Set<String> {
        Set(targets.filter { target in
            completedAt[target].map { $0 > now || now.timeIntervalSince($0) > maximumAge } ?? true
        })
    }
}

/// Welche Code-Bäume ein Vollscan komplett prüft (#649); die übrigen bestätigt er über ihre Bundle-Stempel
/// (`DeepSignatureRevalidation.bundleMetadata`), ihre Komplettprüfung übernimmt der `SignatureRevalidationSchedule`.
enum CompleteTreeSelection: Equatable, Sendable {
    /// Start und manueller Scan: alle am Stück, wie vor #649.
    case all
    /// Bäume, in denen einer der Pfade liegt (Auslöser von Dateiänderungen); leer bei Intervall- und Teilscans.
    case containing(Set<String>)

    init(_ reason: ScanReason) {
        switch reason {
        case .launch, .manual: self = .all
        case .fileChange(let path): self = .containing([path])
        case .interval, .sourceRefresh: self = .containing([])
        }
    }

    /// Für zusammengefasste Anlässe: Bäume beider.
    func union(_ other: Self) -> Self {
        switch (self, other) {
        case let (.containing(paths), .containing(others)): .containing(paths.union(others))
        default: .all
        }
    }

    /// Komplett zu prüfende Ziele aus `targets`. Ein Pfad betrifft ein Ziel, wenn er es selbst ist oder darin liegt;
    /// ein Elternordner (etwa `/Applications`) betrifft keines erkennbar – einen ausgetauschten Baum erkennen die Stempel.
    func targets(in targets: [String]) -> Set<String> {
        switch self {
        case .all:
            return Set(targets)
        case .containing(let paths):
            return Set(targets.filter { target in paths.contains { $0 == target || $0.hasPrefix(target + "/") } })
        }
    }
}
