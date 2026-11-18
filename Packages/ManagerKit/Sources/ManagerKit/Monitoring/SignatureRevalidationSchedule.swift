import Foundation

/// Plan der verteilten Komplettprüfung (#649, Variante B; Blöcke und Sichtbarkeit #662): Statt alle Bäume im
/// Intervall-Vollscan am Stück zu traversieren (`DeepSignatureRevalidation.completeTree`), prüft die `MonitoringEngine` je
/// Durchgang einige Bäume vollständig, gleichmäßig über `period` verteilt.
///
/// **Zusage:** Jeder Baum ist spätestens `maximumAge` nach Beginn seiner letzten Komplettprüfung erneut komplett
/// geprüft – unabhängig von Vollscans und davon, ob Fenster sichtbar sind. Spätestens bei `deadlineAge` (`maximumAge`
/// minus `reserve` für Verzögerungen: Queue, gedrosselte Bäume, Zeitgeber im Hintergrund, Blöcke eines großen Baums)
/// beginnt seine Prüfung, auch bei sichtbaren Livewerten (erzwungener Durchgang). Überfällige Bäume – etwa nach dem
/// Ruhezustand des Macs – folgen im Abstand von `catchUpPause`, ältester zuerst.
///
/// **Ohne sichtbare Livewerte** (kein Fenster, kein Popover misst) zielt der Plan auf `period`, `lead` vor der Frist: Er
/// beginnt jeden Durchgang mit dem Baum der frühesten Frist und hält einen Abstand von `period / Zahl der Bäume` je
/// geprüftem Baum ein, sodass jeder Baum einmal je `period` drankommt und gleich alte Bäume (nach Start oder manuellem
/// Scan) sich verteilen. Nach dem Verdecken wartet er `settle`, bevor er wieder Durchgänge beginnt.
///
/// **Mit sichtbaren Livewerten** schiebt der Plan die Prüfung auf, solange die Frist es erlaubt – der Vorlauf `lead`
/// macht dafür Platz. Erzwingt die Frist einen Durchgang, prüft er alle Bäume, die innerhalb von `forcedHorizon` beginnen
/// müssen (`forcedOrder`): wenige Durchgänge statt vieler, jeder in kleinen Blöcken. Wann ein Baum spätestens beginnen
/// muss, rechnet der Plan mit der Arbeit aller früher fälligen Bäume (`latestStarts`, Codex-Review zu PR 665): Viele gleich
/// alte Bäume (nach Start oder manuellem Scan) beginnen so früh genug, dass auch der letzte samt Blockpausen vor seiner
/// Frist fertig ist.
///
/// **Blöcke:** Ein Durchgang prüft nach dem fälligen Baum weitere in Fristreihenfolge (`dueOrder`), solange er unter
/// `stepBudget` Rechenzeit bleibt; der nächste Durchgang rückt um ebenso viele Abstände weiter. Am Stück rechnet er
/// höchstens `blockBudget`, danach pausiert er `blockPause`; einen großen Baum liest er über mehrere Blöcke zu Ende
/// (`DeepSignatureVerifier.revalidateTree(at:cpuBudget:)`). Gemessen kosteten dieselben Prüfungen einzeln mit Pausen
/// gedrosselt rund 30 % mehr CPU-Zeit als am Stück, in Durchgängen zu etwa acht Bäumen nur noch 5 bis 10 % (kalte Kerne
/// und Caches je Durchgang, siehe `docs/performance/issue-649-verteilte-revalidierung.md`).
///
/// Rein rechnerisch, ohne Zeitgeber: Die Engine fragt `nextStep`, wartet bis zu dessen Zeitpunkt und fragt danach erneut.
public struct SignatureRevalidationSchedule: Sendable, Equatable {
    /// Höchstes Alter der letzten Komplettprüfung eines Baums (Zusage, wie bisher das Intervall des Vollscans).
    public var maximumAge: TimeInterval
    /// Puffer vor `maximumAge`: Spätestens bei `deadlineAge = maximumAge - reserve` beginnt die Prüfung eines Baums.
    public var reserve: TimeInterval
    /// Vorlauf ohne sichtbare Livewerte: Der Plan zielt auf `period = deadlineAge - lead`, damit ein sichtbares Fenster
    /// oder Popover die Prüfung bis zur Frist aufschieben kann. Jede Sekunde Vorlauf kostet anteilig CPU-Zeit.
    public var lead: TimeInterval
    /// Höchster Abstand zweier Schritte, wenn Bäume überfällig sind (Nachholen nach dem Aufwachen).
    public var catchUpPause: TimeInterval
    /// Ein Baum ohne Komplettprüfung, den der Plan schon angestoßen hat (etwa weil er sich während der Prüfung
    /// änderte), kommt frühestens so lange danach erneut – keine Schleife bei einem Bundle, das sich laufend ändert.
    public var retryPause: TimeInterval
    /// Rechenzeit, bis zu der ein Durchgang nach dem fälligen Baum weitere beginnt; `0`: genau einen.
    public var stepBudget: TimeInterval
    /// Höchste Rechenzeit am Stück (ein Block); danach pausiert der Durchgang `blockPause`.
    public var blockBudget: TimeInterval
    public var blockPause: TimeInterval
    /// Ruhe nach dem Verdecken des letzten Fensters oder Popovers mit Livewerten: so lange keine Durchgänge, außer die
    /// Frist verlangt es.
    public var settle: TimeInterval
    /// Ein erzwungener Durchgang prüft alle Bäume, die innerhalb dieser Zeit beginnen müssen.
    public var forcedHorizon: TimeInterval
    /// Geschätzte Wanduhr-Zeit für die Komplettprüfung eines Baums, solange der Plan sie noch nicht gemessen hat (ein
    /// Block samt Pause, großzügig).
    public var defaultTreeWork: TimeInterval

    public init(maximumAge: TimeInterval = 900, reserve: TimeInterval = 30, lead: TimeInterval = 60,
                catchUpPause: TimeInterval = 1, retryPause: TimeInterval = 60, stepBudget: TimeInterval = 1,
                blockBudget: TimeInterval = 0.25, blockPause: TimeInterval = 1, settle: TimeInterval = 60,
                forcedHorizon: TimeInterval = 210, defaultTreeWork: TimeInterval = 2) {
        self.maximumAge = maximumAge
        self.reserve = reserve
        self.lead = lead
        self.catchUpPause = catchUpPause
        self.retryPause = retryPause
        self.stepBudget = stepBudget
        self.blockBudget = blockBudget
        self.blockPause = blockPause
        self.settle = settle
        self.forcedHorizon = forcedHorizon
        self.defaultTreeWork = defaultTreeWork
    }

    /// Alter, bei dem die Prüfung eines Baums spätestens beginnt – auch bei sichtbaren Livewerten.
    public var deadlineAge: TimeInterval { maximumAge - reserve }

    /// Zielabstand zweier Komplettprüfungen desselben Baums ohne sichtbare Livewerte.
    public var period: TimeInterval { deadlineAge - lead }

    /// Ob ein Fenster oder Popover Livewerte misst (`MeasuresWhileVisible` der App).
    public enum LiveViews: Sendable, Equatable {
        /// Keine sichtbaren Livewerte, seit `since` (auf der Zeitachse des Plans); `nil`: seit dem Start.
        case hidden(since: Date?)
        case visible
    }

    /// Der nächste vollständig zu prüfende Baum und wann.
    public struct Step: Equatable, Sendable {
        public let path: String
        public let date: Date
        /// Die Frist verlangt den Durchgang: Er läuft auch bei sichtbaren Livewerten und prüft `forcedOrder`.
        public let isForced: Bool

        public init(path: String, date: Date, isForced: Bool = false) {
            self.path = path
            self.date = date
            self.isForced = isForced
        }
    }

    /// Abstand zweier Schritte bei `count` Bäumen.
    public func gap(forTargetCount count: Int) -> TimeInterval {
        period / Double(max(count, 1))
    }

    /// Nächster Schritt für `targets`, `nil` ohne Ziele. Ohne sichtbare Livewerte der Baum mit der frühesten Frist
    /// (`dueOrder`) im gleichmäßigen Abstand, mit sichtbaren erst, wenn ein Baum spätestens beginnen muss (`latestStarts`:
    /// Frist bei `deadlineAge` abzüglich der Arbeit aller früher fälligen Bäume).
    ///
    /// - Parameters:
    ///   - targets: planbare Ziele, am längsten nicht vom Plan besuchte zuerst – das entscheidet bei gleicher Frist.
    ///   - completedAt: Beginn der letzten Komplettprüfung je Baum (aus `DeepSignatureVerifier.completeCheckAges`).
    ///   - attemptedAt: Wann der Plan Bäume ohne Komplettprüfung zuletzt angestoßen hat.
    ///   - previousStep: Zeitpunkt des vorigen Schritts (beim Start der Planung: der Start).
    ///   - previousBlockSize: Zahl der Bäume, die der vorige Schritt geprüft hat.
    ///   - liveViews: ob Livewerte sichtbar sind.
    ///   - work: gemessene Wanduhr-Zeit der letzten Komplettprüfung je Baum samt Blockpausen (sonst `defaultTreeWork`).
    public func nextStep(
        targets: [String], completedAt: [String: Date], attemptedAt: [String: Date], previousStep: Date,
        previousBlockSize: Int = 1, liveViews: LiveViews = .hidden(since: nil), work: [String: TimeInterval] = [:],
        now: Date
    ) -> Step? {
        let starts = latestStarts(targets, completedAt: completedAt, attemptedAt: attemptedAt, work: work, now: now)
        guard let deadline = starts.first, let latest = starts.map(\.start).min(),
              let earliest = dueDates(targets, completedAt: completedAt, attemptedAt: attemptedAt, age: period,
                                      now: now).first
        else { return nil }
        // Nach einer Zeitumstellung zurück läge der vorige Schritt in der Zukunft; der Plan wartet nie länger als die
        // Abstände des vorigen Blocks.
        let previous = min(previousStep, now)
        let gap = gap(forTargetCount: targets.count)
        let pause = previous.addingTimeInterval(min(catchUpPause, gap))
        let forced = Step(path: deadline.path, date: max(pause, latest), isForced: true)
        guard case .hidden(let since) = liveViews else { return forced }
        var date = max(pause, min(earliest.due, previous.addingTimeInterval(gap * Double(max(previousBlockSize, 1)))))
        if let since { date = max(date, since.addingTimeInterval(settle)) }
        return date <= forced.date ? Step(path: earliest.path, date: date) : forced
    }

    /// `targets` nach Frist, früheste zuerst; bei gleicher Frist in ihrer Reihenfolge. Ein Schritt prüft von vorn.
    public func dueOrder(
        _ targets: [String], completedAt: [String: Date], attemptedAt: [String: Date], now: Date
    ) -> [String] {
        dueDates(targets, completedAt: completedAt, attemptedAt: attemptedAt, age: period, now: now).map(\.path)
    }

    /// Bäume eines erzwungenen Durchgangs in Fristreihenfolge: bis zum letzten, der spätestens `forcedHorizon` nach `now`
    /// beginnen muss (`latestStarts`), samt allen früher fälligen – sie kommen vor ihm dran.
    public func forcedOrder(
        _ targets: [String], completedAt: [String: Date], attemptedAt: [String: Date],
        work: [String: TimeInterval] = [:], now: Date
    ) -> [String] {
        let horizon = now.addingTimeInterval(forcedHorizon)
        let starts = latestStarts(targets, completedAt: completedAt, attemptedAt: attemptedAt, work: work, now: now)
        guard let last = starts.lastIndex(where: { $0.start <= horizon }) else { return [] }
        return starts[...last].map(\.path)
    }

    /// Spätester Beginn je Baum, wenn die Bäume in Fristreihenfolge nacheinander geprüft werden: seine Frist
    /// (`deadlineAge`) abzüglich der Arbeit aller früher fälligen (`work`, sonst `defaultTreeWork`). Fristreihenfolge.
    func latestStarts(
        _ targets: [String], completedAt: [String: Date], attemptedAt: [String: Date], work: [String: TimeInterval],
        now: Date
    ) -> [(path: String, start: Date)] {
        var before: TimeInterval = 0
        return dueDates(targets, completedAt: completedAt, attemptedAt: attemptedAt, age: deadlineAge, now: now)
            .map { entry in
                defer { before += work[entry.path] ?? defaultTreeWork }
                return (entry.path, entry.due == .distantPast ? .distantPast : entry.due.addingTimeInterval(-before))
            }
    }

    /// Ob ein Baum mit letzter Komplettprüfung `completed` seine Frist zu verfehlen droht. Ein noch nicht begonnener ab
    /// seinem spätesten Beginn (`deadlineAge`); ein laufender (`running`) erst ab der Hälfte der Reserve, denn die Reserve
    /// gehört seinen eigenen Blöcken. Dann entfällt die Pause zwischen zwei Blöcken – die Zusage geht vor; ein schon
    /// überfälliger Baum (`maximumAge`) wird im üblichen Takt nachgeholt.
    public func deadlineIsPressing(completed: Date?, running: Bool = false, now: Date) -> Bool {
        guard let completed, completed <= now else { return false }
        let age = now.timeIntervalSince(completed)
        return age >= deadlineAge + (running ? reserve / 2 : 0) && age < maximumAge
    }

    /// Frist je Ziel (letzte Komplettprüfung plus `age`), früheste zuerst (stabil). Ein Prüfzeitpunkt in der Zukunft
    /// (Uhr zurückgestellt) ist nicht belastbar und sofort fällig; ein solcher Versuch zählt als eben.
    private func dueDates(
        _ targets: [String], completedAt: [String: Date], attemptedAt: [String: Date], age: TimeInterval, now: Date
    ) -> [(path: String, due: Date)] {
        targets.enumerated().map { index, target in
            let due: Date
            if let completed = completedAt[target] {
                due = completed <= now ? completed.addingTimeInterval(age) : .distantPast
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
