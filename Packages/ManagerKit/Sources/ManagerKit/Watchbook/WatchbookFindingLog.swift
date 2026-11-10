import Foundation

/// Befunde des Wachbuchs mit Beginn und Ende (Spec 2026-11-08 §5.1, TM-12.3): Nach jedem 10-s-Punkt wertet das
/// Protokoll die Regeln aus `FindingRules` über die jüngsten Punkte aus und liefert, was sich geändert hat, als
/// Wachbuch-Ereignisse – Beginn (ohne Ende), schärferer Ton, Ende. Ein späterer Eintrag mit derselben ID ersetzt im
/// Wachbuch den früheren.
///
/// Ein Befund bleibt über Art und Bezug derselbe, solange er läuft: Beginn und ID ändern sich nicht, auch wenn sein
/// Beginn nach `maximumSpan` aus dem Fenster fällt. Solange einer läuft, reicht das Fenster bis `span` vor seinen Beginn
/// zurück, damit die Hysterese ihn über Lücken hinweg fortsetzt (Ruhezustand beendet keinen Befund). Verschwindet ein
/// laufender Befund ohne Ende aus der Auswertung (sein Abschnitt ist ganz aus dem Fenster gefallen), endet er mit dem
/// letzten Punkt, an dem er noch lief. Rein und ohne Uhr.
struct WatchbookFindingLog {
    /// Art und Bezug: bezeichnen einen Befund über seine ganze Dauer.
    private struct Key: Hashable {
        let kind: SystemFinding.Kind
        let subject: String

        init(_ finding: SystemFinding) {
            kind = finding.kind
            subject = finding.subjectKey
        }
    }

    private struct Running {
        var finding: SystemFinding
        /// Letzter Punkt, an dem er noch lief.
        var lastSeen: Date
    }

    let thresholds: FindingThresholds
    /// Grundfenster der Auswertung; deckt Mindest- und Ruhezeiten sowie die Fenster für Swap und Akku.
    let span: TimeInterval
    /// Weiter reicht das Fenster nie zurück, auch nicht für einen laufenden Befund (Speicher und Rechenzeit).
    let maximumSpan: TimeInterval
    /// So lange bleibt ein beendeter Befund in `findings` (für die volle Auflösung um ihn).
    let endedRetention: TimeInterval
    private var points: [WatchbookPoint] = []
    private var processSamples: [ProcessLoadSample] = []
    private var running: [Key: Running] = [:]
    /// Ende des zuletzt beendeten Befunds je Schlüssel; ältere Abschnitte werden nicht erneut gemeldet.
    private var lastEnd: [Key: Date] = [:]
    private var ended: [SystemFinding] = []

    init(thresholds: FindingThresholds = .standard,
         span: TimeInterval = TimeInterval(SampleHistory.span.components.seconds),
         maximumSpan: TimeInterval = 6 * 3_600) {
        self.thresholds = thresholds
        self.span = span
        self.maximumSpan = maximumSpan
        endedRetention = WatchbookResolution.findingMargin + WatchbookResolution(thresholds: thresholds).holdback
    }

    /// Laufende und kürzlich beendete Befunde, nach Beginn.
    var findings: [SystemFinding] {
        (running.values.map(\.finding) + ended).sorted { $0.start < $1.start }
    }

    /// Trägt einen 10-s-Punkt und die Prozesslast desselben Takts ein und liefert die geänderten Befunde.
    mutating func record(_ point: WatchbookPoint, processes: ProcessLoadSample) -> [WatchbookEvent] {
        points.append(point)
        processSamples.append(processes)
        trim(now: point.time)
        let evaluated = FindingRules.findings(in: points, thresholds: thresholds)
            + FindingRules.processFindings(in: processSamples, thresholds: thresholds)
        var changes: [SystemFinding] = []
        var stillRunning: Set<Key> = []
        for finding in evaluated {
            let key = Key(finding)
            if let end = finding.end {
                changes += close(key, at: end, evaluated: finding)
            } else {
                stillRunning.insert(key)
                changes += open(key, finding, at: point.time)
            }
        }
        for (key, run) in running where !stillRunning.contains(key) {
            changes += close(key, at: run.lastSeen, evaluated: nil)
        }
        ended.removeAll { ($0.end ?? $0.start).addingTimeInterval(endedRetention) < point.time }
        return changes.map(\.watchbookEvent)
    }

    /// Beendet alle laufenden Befunde mit ihrem letzten Punkt und beginnt von vorn – beim Ausschalten oder Beenden, denn
    /// ohne Messung lässt sich ihr Ende nicht mehr feststellen.
    mutating func closeAll() -> [WatchbookEvent] {
        let closed = running.values.sorted { $0.finding.start < $1.finding.start }.map {
            ended(copyOf: $0.finding, at: $0.lastSeen)
        }
        self = WatchbookFindingLog(thresholds: thresholds, span: span, maximumSpan: maximumSpan)
        return closed.map(\.watchbookEvent)
    }

    // MARK: Zustand

    /// Neuer Befund oder Fortsetzung; liefert ihn, wenn er neu ist oder sein Ton sich geändert hat.
    private mutating func open(_ key: Key, _ finding: SystemFinding, at time: Date) -> [SystemFinding] {
        guard var run = running[key] else {
            guard finding.start > lastEnd[key] ?? .distantPast else { return [] }
            running[key] = Running(finding: finding, lastSeen: time)
            return [finding]
        }
        run.lastSeen = time
        defer { running[key] = run }
        // Der Ton wird nur schärfer: Fällt die Spitze nach `maximumSpan` aus dem Fenster, bleibt er kritisch.
        guard finding.tone == .critical, run.finding.tone != .critical else { return [] }
        let previous = run.finding
        run.finding = SystemFinding(kind: previous.kind, tone: finding.tone, reason: finding.reason,
                                    start: previous.start, end: nil, evidence: finding.evidence,
                                    subject: previous.subject)
        return [run.finding]
    }

    /// Ende eines laufenden Befunds oder ein Befund, der zwischen zwei Auswertungen begann und endete. Bereits gemeldete
    /// Abschnitte bleiben stumm.
    private mutating func close(_ key: Key, at end: Date, evaluated: SystemFinding?) -> [SystemFinding] {
        let finding: SystemFinding
        if let run = running[key], end >= run.finding.start {
            running[key] = nil
            finding = ended(copyOf: run.finding, at: end)
        } else if let evaluated, running[key] == nil, evaluated.start > lastEnd[key] ?? .distantPast {
            finding = evaluated
        } else {
            return []
        }
        lastEnd[key] = finding.end
        ended.append(finding)
        return [finding]
    }

    private func ended(copyOf finding: SystemFinding, at end: Date) -> SystemFinding {
        SystemFinding(kind: finding.kind, tone: finding.tone, reason: finding.reason, start: finding.start, end: end,
                      evidence: finding.evidence, subject: finding.subject)
    }

    /// Hält das Fenster: `span` vor dem neuesten Punkt, bei laufenden Befunden bis `span` vor den frühesten Beginn,
    /// höchstens `maximumSpan`.
    private mutating func trim(now: Date) {
        let earliest = running.values.map(\.finding.start).min().map { $0.addingTimeInterval(-span) }
        let cutoff = max(min(now.addingTimeInterval(-span), earliest ?? .distantFuture),
                         now.addingTimeInterval(-maximumSpan))
        points.removeAll { $0.time < cutoff }
        processSamples.removeAll { $0.time < cutoff }
    }
}
