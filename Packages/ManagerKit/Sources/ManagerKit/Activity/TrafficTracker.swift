import Foundation

/// Errechnet aus aufeinanderfolgenden nettop-Messungen Raten und Summen (Spec §3):
///
/// - Rate = Byte-Differenz / Zeit seit den letzten Werten **dieses** Zählers, geglättet über die letzten
///   `smoothingWindow` Schritte – je Prozess aus seiner Prozesszeile (geschlossene Verbindungen zählen so weiter mit), je
///   Verbindung aus ihrer Zeile. Nach einer Lücke (verschwunden, leere Felder) verteilt sich die Differenz so auf die
///   ganze Lücke statt auf einen Schritt.
/// - Die erste Messung ist nur Basis: keine Rate, keine Summe, keine „neu“-Markierung (sonst wäre beim Öffnen alles neu).
/// - Was danach erstmals auftaucht, zählt vollständig: eine Verbindung (ihr Zähler läuft seit Öffnen des Sockets) und ein
///   Prozess, der nach dem Öffnen der Ansicht gestartet ist – sonst bliebe kurzer Verkehr (curl lädt in < 2 s) unsichtbar.
///   Ein Prozess, der schon vorher lief oder dessen Startzeit unbekannt ist, beginnt als Basis.
/// - Prozesse gelten unter `ProcessKey` (PID + Startzeit aus `ProcessTraffic.startTime`). Ohne Startzeit (Prozess
///   endete, bevor seine Zeile erfasst wurde) ist ein bekannter Prozess mit derselben PID derselbe – sonst begänne
///   eine zweite Zeile, und seine Abschlusswerte würden Basis statt Fortschreibung.
/// - Sinkt ein Zähler (neuer Socket, neuer Prozess unter gleichem Schlüssel), gilt für diesen Schritt Rate 0 und der
///   neue Stand als Basis.
/// - Neue Verbindungen sind `highlightDuration` lang „neu“; verschwundene Prozesse und Verbindungen bleiben so lange
///   ausgegraut (Rate 0) stehen und entfallen dann.
/// - Lauschende Sockets (`Listen`) gehören zu „Dienste“ und werden übergangen.
/// - Plausibilitätsdeckel: Mit Byte-Zählern der Schnittstellen (`record(_:)`) liegt die geglättete Gesamtrate nie über
///   dem, was alle Schnittstellen im Glättungsfenster übertragen haben; sonst werden alle Raten dieser Messung
///   anteilig gekürzt (`rateScale()`).
public struct TrafficTracker: Sendable {
    public static let smoothingWindow = 3
    public static let highlightDuration: Duration = .seconds(10)
    /// 60 Messungen à 2 s = 2 min für die Sparkline.
    public static let historyLength = 60
    /// Anteil des Takts, den ein Schritt für den Deckel mindestens dauert (nettop misst nie schneller, schwankt aber um
    /// wenige Millisekunden).
    static let minimumStepShare = 0.9
    /// Höchstens so viele Lesungen der Schnittstellen bleiben gemerkt.
    static let maximumInterfaceReadings = 16

    private let wallClock: @Sendable () -> UInt64
    private let sampleInterval: Duration
    private var processes: [ProcessKey: ProcessState] = [:]
    private var lastInstant: ContinuousClock.Instant?
    /// Wanduhrzeit der ersten Messung (µs seit 1970) – Prozesse, die danach starten, zählen vollständig.
    private var observationStart: UInt64?
    private var history: [TrafficRate] = []
    /// Zeitpunkte der letzten Messungen, höchstens `smoothingWindow + 1`: Anfang und Ende des Glättungsfensters.
    private var recentInstants: [ContinuousClock.Instant] = []
    /// Lesungen der Schnittstellenzähler, älteste zuerst.
    private var interfaceReadings: [InterfaceByteReading] = []

    /// - Parameters:
    ///   - wallClock: aktuelle Zeit in µs seit 1970, in derselben Einheit wie `ProcessTraffic.startTime`.
    ///   - sampleInterval: Takt der Messungen (nettop `-s`); für den Deckel dauert ein Schritt mindestens
    ///     `minimumStepShare` davon, auch wenn die Zeitpunkte enger liegen.
    public init(wallClock: @escaping @Sendable () -> UInt64 = TrafficTracker.microsecondsSince1970,
                sampleInterval: Duration = .seconds(2)) {
        self.wallClock = wallClock
        self.sampleInterval = sampleInterval
    }

    /// Merkt sich die Byte-Zähler der Schnittstellen für den Plausibilitätsdeckel – gelesen vor dem Start von nettop und
    /// zu jeder Messung, bevor sie ausgewertet wird.
    public mutating func record(_ reading: InterfaceByteReading) {
        interfaceReadings = Array((interfaceReadings + [reading]).suffix(Self.maximumInterfaceReadings))
    }

    /// Jetzt in µs seit 1970 (Einheit von `p_starttime`).
    public static func microsecondsSince1970() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
    }

    public mutating func update(with sample: NettopSample, at instant: ContinuousClock.Instant) -> TrafficReport {
        let step = Step(instant: instant, previous: lastInstant)
        lastInstant = instant
        recentInstants = Array((recentInstants + [instant]).suffix(Self.smoothingWindow + 1))
        let openedAt = observedSince(baseline: instant)
        var seen: Set<ProcessKey> = []
        for process in sample.processes {
            let key = key(of: process)
            guard seen.insert(key).inserted else { continue }
            if var state = processes[key] {
                state.update(with: process, step: step)
                processes[key] = state
            } else {
                let startedAfterOpening = !step.isBaseline && process.startTime.map { $0 >= openedAt } == true
                processes[key] = ProcessState(process, step: step, countsFully: startedAfterOpening)
            }
        }
        for key in processes.keys where !seen.contains(key) {
            processes[key]?.markGone(at: instant)
        }
        processes = processes.filter { !Self.hasExpired($0.value.goneSince, at: instant) }
        let scale = step.isBaseline ? 1 : rateScale()
        if !step.isBaseline {
            for key in processes.keys {
                processes[key]?.recordHistory(scale: scale)
            }
        }

        let activities = processes.map { $0.value.activity(key: $0.key, at: instant, scale: scale) }
            .sorted { $0.key < $1.key }
        let total = activities.reduce(TrafficRate.zero) { $0 + $1.rate }
        if !step.isBaseline { history = Array((history + [total]).suffix(Self.historyLength)) }
        return TrafficReport(processes: activities, total: total, history: history,
                             skippedLineCount: sample.skippedLineCount)
    }

    /// Faktor für alle Raten der aktuellen Messung (Plausibilitätsdeckel): Die geglättete Gesamtrate darf nicht über dem
    /// liegen, was alle Schnittstellen von der letzten Lesung vor Beginn des Glättungsfensters bis zur jüngsten Lesung
    /// übertragen haben, verteilt auf das Fenster. Das Fenster dauert je Schritt mindestens `minimumStepShare` des Takts –
    /// auch falsche, zu enge Zeitpunkte ergeben so keine Rate über dem Verkehr der Schnittstellen. Ohne Lesung vor dem
    /// Fenster oder ohne Lesung nach seinem Ende gibt es keinen Deckel (1).
    private func rateScale() -> Double {
        guard let start = recentInstants.first, let end = recentInstants.last, end > start,
              let latest = interfaceReadings.last, latest.instant >= end,
              let before = interfaceReadings.last(where: { $0.instant <= start }) else { return 1 }
        let shortest = sampleInterval * (Self.minimumStepShare * Double(recentInstants.count - 1))
        let ceiling = Double(latest.bytesTransferred(since: before)) / max(end - start, shortest).seconds
        let total = processes.values.reduce(0) { $0 + ($1.counter?.rate.total ?? 0) }
        return total > ceiling ? ceiling / total : 1
    }

    /// Schlüssel einer Prozesszeile; ohne Startzeit der bekannte (noch nicht entfallene) Prozess mit derselben PID –
    /// bei mehreren der zuletzt gestartete –, sonst Startzeit 0.
    private func key(of process: ProcessTraffic) -> ProcessKey {
        if let startTime = process.startTime { return ProcessKey(pid: process.pid, startTime: startTime) }
        return processes.keys.filter { $0.pid == process.pid }.max { $0.startTime < $1.startTime }
            ?? ProcessKey(pid: process.pid, startTime: 0)
    }

    /// Wanduhrzeit der ersten Messung; beim ersten Aufruf festgelegt – zurückgerechnet auf ihren Zeitpunkt in nettops
    /// Takt, der wegen der gepufferten Ausgabe Intervalle vor ihrer Auswertung liegen kann.
    private mutating func observedSince(baseline instant: ContinuousClock.Instant) -> UInt64 {
        if let observationStart { return observationStart }
        let age = max(.zero, ContinuousClock.now - instant)
        let start = wallClock().subtractingClamped(UInt64(age.seconds * 1_000_000))
        observationStart = start
        return start
    }

    static func hasExpired(_ goneSince: ContinuousClock.Instant?, at instant: ContinuousClock.Instant) -> Bool {
        goneSince.map { instant - $0 >= highlightDuration } ?? false
    }

    /// Zeitpunkt der aktuellen und der vorigen Messung.
    struct Step {
        let instant: ContinuousClock.Instant
        /// `nil` bei der ersten Messung (Basis).
        let previous: ContinuousClock.Instant?

        var isBaseline: Bool { previous == nil }
    }
}

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 { self >= other ? self - other : 0 }
}

/// Kumulative Byte-Zähler einer Zeile über Messungen: letzte Stände samt Zeitpunkt, die letzten Schrittraten und die
/// Summe seit Beginn der Beobachtung.
struct TrafficCounter: Hashable, Sendable {
    private var lastReceived: UInt64
    private var lastSent: UInt64
    private var lastInstant: ContinuousClock.Instant
    private var recentRates: [TrafficRate] = []
    private(set) var transferred = ByteTotals.zero

    /// Basis: Der Stand zum Zeitpunkt `instant` zählt nicht.
    init(received: UInt64, sent: UInt64, at instant: ContinuousClock.Instant) {
        lastReceived = received
        lastSent = sent
        lastInstant = instant
    }

    /// Ein Zähler, der seit `start` von 0 an lief: Der ganze Stand gilt als übertragen zwischen `start` und `instant`.
    static func counting(received: UInt64, sent: UInt64, since start: ContinuousClock.Instant,
                         until instant: ContinuousClock.Instant) -> TrafficCounter {
        var counter = TrafficCounter(received: 0, sent: 0, at: start)
        counter.record(received: received, sent: sent, at: instant)
        return counter
    }

    var rate: TrafficRate { .average(recentRates) }

    /// Neuer Stand: Die Differenz zählt zur Summe; die Rate teilt sie durch die Zeit seit den letzten Werten dieses
    /// Zählers (ohne Zeitabstand keine Rate).
    mutating func record(received: UInt64, sent: UInt64, at instant: ContinuousClock.Instant) {
        let seconds = (instant - lastInstant).seconds
        defer {
            lastReceived = received
            lastSent = sent
            lastInstant = instant
        }
        // Ein sinkender Zähler gehört zu einem neuen Socket bzw. Prozess: Rate 0 für diesen Schritt und frische
        // Glättung – die Raten des Vorgängers dürfen nicht nachwirken.
        guard received >= lastReceived, sent >= lastSent else {
            recentRates = [.zero]
            return
        }
        let deltaIn = received - lastReceived
        let deltaOut = sent - lastSent
        transferred.received += deltaIn
        transferred.sent += deltaOut
        guard seconds > 0 else { return }
        let rate = TrafficRate(download: Double(deltaIn) / seconds, upload: Double(deltaOut) / seconds)
        recentRates = Array((recentRates + [rate]).suffix(TrafficTracker.smoothingWindow))
    }

    /// Ohne neue Werte (verschwunden, leere Felder) ist die Rate 0; der letzte Stand und sein Zeitpunkt bleiben.
    mutating func pause() { recentRates = [] }

    /// Zähler nach einer Zeile mit möglicherweise leeren Feldern: ohne Werte pausiert, sonst fortgeschrieben oder neu –
    /// als Basis oder, bei `countsFully` nach der ersten Messung, mit dem ganzen Stand seit der vorigen Messung.
    static func advancing(_ counter: TrafficCounter?, received: UInt64?, sent: UInt64?, step: TrafficTracker.Step,
                          countsFully: Bool) -> TrafficCounter? {
        guard let received, let sent else {
            var paused = counter
            paused?.pause()
            return paused
        }
        if var counter {
            counter.record(received: received, sent: sent, at: step.instant)
            return counter
        }
        if countsFully, let previous = step.previous {
            return .counting(received: received, sent: sent, since: previous, until: step.instant)
        }
        return TrafficCounter(received: received, sent: sent, at: step.instant)
    }
}

/// Zustand einer Verbindungszeile, geführt unter ihrem `ConnectionKey`.
///
/// Grenze: Ändert sich der `ConnectionKey` eines bestehenden Sockets (Ordinalverschiebung bei gleichen Sockets, ein
/// später verbundener UDP-Socket, Rückkehr nach der Ausgrauzeit), beginnt eine neue Zeile mit dem kumulativen Zähler
/// des Sockets – die Einzelsumme dieser Verbindungszeile kann dann doppelt zählen. Prozesssummen und Gesamtrate
/// stammen aus der Prozesszeile und sind nicht betroffen.
private struct ConnectionState: Sendable {
    var connection: ConnectionTraffic
    var counter: TrafficCounter?
    let firstSeen: ContinuousClock.Instant
    let isFromBaseline: Bool
    var goneSince: ContinuousClock.Instant?

    init(_ connection: ConnectionTraffic, step: TrafficTracker.Step) {
        self.connection = connection
        firstSeen = step.instant
        isFromBaseline = step.isBaseline
        counter = nil
        advanceCounter(step: step)
    }

    mutating func update(with connection: ConnectionTraffic, step: TrafficTracker.Step) {
        self.connection = connection
        advanceCounter(step: step)
        goneSince = nil
    }

    /// Eine nach der ersten Messung aufgetauchte Verbindung zählt seit Öffnen ihres Sockets vollständig.
    private mutating func advanceCounter(step: TrafficTracker.Step) {
        counter = TrafficCounter.advancing(counter, received: connection.bytesIn, sent: connection.bytesOut,
                                           step: step, countsFully: !isFromBaseline)
    }

    mutating func markGone(at instant: ContinuousClock.Instant) {
        goneSince = goneSince ?? instant
        counter?.pause()
    }

    /// - Parameter scale: Faktor des Plausibilitätsdeckels (`TrafficTracker.rateScale()`).
    func activity(key: ConnectionKey, at instant: ContinuousClock.Instant, scale: Double) -> ConnectionActivity {
        ConnectionActivity(
            key: key, connection: connection, rate: (counter?.rate ?? .zero).scaled(by: scale),
            transferred: counter?.transferred ?? .zero,
            isNew: goneSince == nil && !isFromBaseline && instant - firstSeen < TrafficTracker.highlightDuration,
            isGone: goneSince != nil
        )
    }
}

private struct ProcessState: Sendable {
    var shortName: String
    var counter: TrafficCounter?
    /// Nach dem Öffnen der Ansicht gestartet: Der ganze Stand zählt, auch wenn die ersten Werte später kommen.
    let countsFully: Bool
    var connections: [ConnectionKey: ConnectionState] = [:]
    var goneSince: ContinuousClock.Instant?
    /// Rate je Messung seit seinem Auftauchen, älteste zuerst (höchstens `TrafficTracker.historyLength`).
    private(set) var history: [TrafficRate] = []
    /// Seine lauschenden Sockets laut letzter Meldung (beendet: die letzten bekannten).
    var listeningSockets: [ConnectionTraffic] = []
    /// Benutzer laut letzter lesbarer Meldung.
    var uid: UInt32?

    init(_ process: ProcessTraffic, step: TrafficTracker.Step, countsFully: Bool) {
        shortName = process.shortName
        self.countsFully = countsFully
        counter = TrafficCounter.advancing(nil, received: process.bytesIn, sent: process.bytesOut, step: step,
                                           countsFully: countsFully)
        updateConnections(with: process.connections, step: step)
        listeningSockets = process.connections.filter(\.isListening)
        uid = process.uid
    }

    mutating func update(with process: ProcessTraffic, step: TrafficTracker.Step) {
        shortName = process.shortName
        counter = TrafficCounter.advancing(counter, received: process.bytesIn, sent: process.bytesOut, step: step,
                                           countsFully: countsFully)
        goneSince = nil
        updateConnections(with: process.connections, step: step)
        listeningSockets = process.connections.filter(\.isListening)
        uid = process.uid ?? uid
    }

    mutating func markGone(at instant: ContinuousClock.Instant) {
        goneSince = goneSince ?? instant
        counter?.pause()
        for key in connections.keys {
            connections[key]?.markGone(at: instant)
        }
    }

    /// Hängt die aktuelle Rate, gekürzt um den Plausibilitätsdeckel, an den Verlauf; ausgegraut ist sie 0.
    mutating func recordHistory(scale: Double) {
        history = Array((history + [(counter?.rate ?? .zero).scaled(by: scale)]).suffix(TrafficTracker.historyLength))
    }

    /// - Parameter scale: Faktor des Plausibilitätsdeckels (`TrafficTracker.rateScale()`) für seine und die Raten seiner
    ///   Verbindungen.
    func activity(key: ProcessKey, at instant: ContinuousClock.Instant, scale: Double) -> ProcessActivity {
        ProcessActivity(
            key: key, shortName: shortName, rate: (counter?.rate ?? .zero).scaled(by: scale),
            transferred: counter?.transferred ?? .zero,
            connections: connections.map { $0.value.activity(key: $0.key, at: instant, scale: scale) }
                .sorted { $0.key < $1.key },
            isGone: goneSince != nil, history: history, listeningSockets: listeningSockets, uid: uid
        )
    }

    /// Ordnet die Zeilen ihren bisherigen Verbindungen zu; gleich aussehende Sockets zählen der Reihe nach.
    private mutating func updateConnections(with lines: [ConnectionTraffic], step: TrafficTracker.Step) {
        var updated: [ConnectionKey: ConnectionState] = [:]
        var ordinals: [ConnectionKey: Int] = [:]
        for connection in lines where !connection.isListening {
            let base = ConnectionKey(connection, ordinal: 0)
            let ordinal = ordinals[base, default: 0]
            ordinals[base] = ordinal + 1
            let key = ConnectionKey(connection, ordinal: ordinal)
            if var state = connections[key] {
                state.update(with: connection, step: step)
                updated[key] = state
            } else {
                updated[key] = ConnectionState(connection, step: step)
            }
        }
        for (key, var state) in connections where updated[key] == nil {
            state.markGone(at: step.instant)
            if !TrafficTracker.hasExpired(state.goneSince, at: step.instant) { updated[key] = state }
        }
        connections = updated
    }
}
