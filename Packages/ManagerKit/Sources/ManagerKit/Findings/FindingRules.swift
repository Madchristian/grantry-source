import Foundation

/// Die Befundregeln (Spec 2026-11-08 §5.1) als reine Funktionen über Messreihen: Wachbuch-Punkte für den ganzen Mac,
/// Prozesslast je Takt für die Dauerlast einzelner Prozesse; dazu neue erreichbare Dienste aus dem Verlauf. Keine Uhr –
/// alle Zeiten stammen aus den Reihen (#214). Die Reihen sollten so dicht sein wie Takt oder Wachbuch-Punkte; Minutenwerte sind für `maximumGap` lauter Lücken.
public enum FindingRules {
    /// Alle Regeln für den ganzen Mac, nach Beginn geordnet.
    public static func findings(in points: [WatchbookPoint],
                                thresholds: FindingThresholds = .standard) -> [SystemFinding] {
        let ordered = points.sorted { $0.time < $1.time }
        return SystemFinding.Kind.allCases
            .flatMap { findings(of: $0, ordered: ordered, thresholds: thresholds) }
            .sorted { ($0.start, $0.kind.rawValue) < ($1.start, $1.kind.rawValue) }
    }

    /// Eine Regel für den ganzen Mac; `processLoad` braucht Prozesslast (`processFindings`), `throttling` die Sensoren
    /// des Helpers (`throttlingFindings`), die Datenträger-Befunde das Volume-Inventar (`storageFindings`) – sie
    /// ergeben hier nichts.
    public static func findings(of kind: SystemFinding.Kind, in points: [WatchbookPoint],
                                thresholds: FindingThresholds = .standard) -> [SystemFinding] {
        findings(of: kind, ordered: points.sorted { $0.time < $1.time }, thresholds: thresholds)
    }

    /// Dauerlast je Prozess. Ein Prozess ist PID plus Startzeit: Eine neu vergebene PID setzt keinen Befund fort.
    public static func processFindings(in samples: [ProcessLoadSample],
                                       thresholds: FindingThresholds = .standard) -> [SystemFinding] {
        let ordered = samples.sorted { $0.time < $1.time }
        let limit = thresholds.processLoad.limit
        // Nur Prozesse, die die Schwelle je überschreiten, brauchen eine eigene Reihe.
        let candidates = Set(ordered.flatMap { sample in
            (sample.processes ?? [:]).compactMap { key, load in (load.coreShare ?? 0) > limit ? key : nil }
        })
        return candidates.sorted().flatMap { key in
            var name: WatchbookSubject?
            let series = ordered.map { sample -> FindingSample in
                guard let processes = sample.processes else { return FindingSample(time: sample.time, value: nil) }
                guard let load = processes[key] else { return FindingSample(time: sample.time, value: 0) }
                name = load.subject ?? name
                return FindingSample(time: sample.time, value: load.coreShare)
            }
            return findings(of: .processLoad, series: series, subject: .process(key, name), thresholds: thresholds)
        }.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }

    /// Drosselung aus den Sensor-Messungen des Helpers. Belegwerte als Anteil am Höchsttakt: Grenze, niedrigster und
    /// mittlerer Takt, solange die Regel galt. Ohne Helper gibt es keinen Takt und damit keinen Befund; dann bleibt
    /// der thermische Zustand selbst (`thermalState`).
    public static func throttlingFindings(in samples: [ThrottlingSample],
                                          thresholds: FindingThresholds = .standard) -> [SystemFinding] {
        let series = throttlingSeries(samples.sorted { $0.time < $1.time }, thresholds: thresholds)
        return findings(of: .throttling, series: series, subject: nil, thresholds: thresholds).map { finding in
            SystemFinding(kind: finding.kind, tone: finding.tone, reason: finding.reason, start: finding.start,
                          end: finding.end,
                          evidence: .init(limit: thresholds.throttlingClock, peak: 1 - finding.evidence.peak,
                                          mean: 1 - finding.evidence.mean),
                          subject: nil)
        }
    }

    /// Neuer aus dem Netz erreichbarer Dienst (Startsatz §5.1) aus dem Verlauf: ein neuer Lauscher oder ein Wechsel von
    /// „nur dieser Mac“ ins Netz – dieselbe Auswahl wie die Kachel „Von außen erreichbar“
    /// (`NetworkListener.countsAsExposed`: keine Dienste von macOS, keine vermutlichen Clients). Ein Augenblick: Beginn
    /// und Ende sind der Zeitpunkt der Erkennung. Belegwert ist der eine Dienst.
    public static func exposedServiceFindings(in changes: [ChangeEvent], currentUID: UInt32,
                                              thresholds: FindingThresholds = .standard) -> [SystemFinding] {
        changes.compactMap { change -> SystemFinding? in
            guard case .networkListener(let listener)? = change.after, listener.countsAsExposed else { return nil }
            switch (change.kind, change.before) {
            case (.added, _): break
            case (.modified, .networkListener(let before)?) where !before.reachability.isExposed: break
            default: return nil
            }
            let subject = SystemFinding.Subject.networkService(
                listenerID: listener.id,
                name: WatchbookSubject(processNamed: listener.processName, uid: listener.uid, currentUID: currentUID))
            let rule = thresholds.exposedService
            return SystemFinding(kind: .exposedService, tone: .finding,
                                 reason: reason(for: .exposedService, tone: .finding, subject: subject,
                                                thresholds: thresholds),
                                 start: change.detectedAt, end: change.detectedAt,
                                 evidence: .init(limit: rule.limit, peak: 1, mean: 1), subject: subject)
        }.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }

    /// Abschlag vom Höchsttakt je Messung. Von den Leistungsclustern über der Lastgrenze zählt der schnellste: Gedrosselt
    /// ist der Mac erst, wenn auch er unter der Taktgrenze bleibt. Was die Bedingung schon verneint (Druck darunter,
    /// kein Cluster ausgelastet), ist ruhig (0); fehlt sonst ein Wert, ist der Punkt nicht gemessen.
    static func throttlingSeries(_ samples: [ThrottlingSample], thresholds: FindingThresholds) -> [FindingSample] {
        samples.map { FindingSample(time: $0.time, value: throttlingValue($0, thresholds: thresholds)) }
    }

    private static func throttlingValue(_ sample: ThrottlingSample, thresholds: FindingThresholds) -> Double? {
        let elevated = sample.pressure.map { $0 >= thresholds.throttlingPressure }
        if elevated == false { return 0 }
        let measured = (sample.performanceClusters ?? []).compactMap { cluster in
            cluster.load.flatMap { load in cluster.clockShare.map { (load: load, clockShare: $0) } }
        }
        guard !measured.isEmpty else { return nil }
        guard let fastest = measured.filter({ $0.load > thresholds.throttlingLoad }).map(\.clockShare).max() else {
            return 0
        }
        guard elevated == true else { return nil }
        return fastest < thresholds.throttlingClock ? 1 - fastest : 0
    }

    // MARK: Reihen

    private static func findings(of kind: SystemFinding.Kind, ordered points: [WatchbookPoint],
                                 thresholds: FindingThresholds) -> [SystemFinding] {
        let series: [FindingSample]
        switch kind {
        case .systemLoad: series = samples(of: .cpuTotal, in: points)
        case .memoryPressure: series = samples(of: .memoryPressure, in: points)
        case .thermalState: series = samples(of: .thermalState, in: points)
        case .sustainedUpload: series = samples(of: .networkSent, in: points)
        case .diskLoad:
            series = points.map { point in
                let measured = [point.values[.diskRead], point.values[.diskWrite]].compactMap(\.self)
                return FindingSample(time: point.time, value: measured.isEmpty ? nil : measured.reduce(0, +))
            }
        case .swapGrowth:
            series = growth(of: samples(of: .swapUsed, in: points), within: thresholds.swapGrowthWindow,
                            maximumGap: thresholds.maximumGap)
        case .batteryDrain:
            series = drainPerHour(in: points, window: thresholds.batteryDrainWindow, maximumGap: thresholds.maximumGap)
        case .processLoad, .throttling, .exposedService, .extensionRisk, .volumeFull, .smartFailure, .staleSnapshots:
            return []
        }
        return findings(of: kind, series: series, subject: nil, thresholds: thresholds)
    }

    private static func samples(of metric: WatchbookMetric, in points: [WatchbookPoint]) -> [FindingSample] {
        points.map { FindingSample(time: $0.time, value: $0.values[metric]) }
    }

    /// Zuwachs gegenüber dem kleinsten Wert der letzten `window` Sekunden desselben lückenlosen Abschnitts – über
    /// einen Ruhezustand hinweg wird nicht verglichen.
    static func growth(of samples: [FindingSample], within window: TimeInterval,
                       maximumGap: TimeInterval) -> [FindingSample] {
        // Aufsteigende Minima des Fensters ab `head`: vorn das kleinste.
        var minima: [(time: Date, value: Double)] = []
        var head = 0
        var previous: Date?
        return samples.map { sample in
            guard let value = sample.value else {
                (minima, head, previous) = ([], 0, nil)
                return sample
            }
            if let previous, sample.time.timeIntervalSince(previous) > maximumGap { (minima, head) = ([], 0) }
            previous = sample.time
            while head < minima.count, sample.time.timeIntervalSince(minima[head].time) > window { head += 1 }
            while minima.count > head, let last = minima.last, last.value >= value { minima.removeLast() }
            minima.append((sample.time, value))
            if head > 64 { (minima, head) = (Array(minima[head...]), 0) }
            return FindingSample(time: sample.time, value: value - minima[head].value)
        }
    }

    /// Entladung je Stunde (Anteil 0…1) über die letzten `window` Sekunden am Akku. Am Netzteil gibt es keine
    /// Entladung (0); ohne Stromquelle oder Ladestand und vor dem ersten vollen Fenster am Akku ist sie nicht gemessen.
    static func drainPerHour(in points: [WatchbookPoint], window: TimeInterval,
                             maximumGap: TimeInterval) -> [FindingSample] {
        var segment: [(time: Date, charge: Double)] = []
        var anchor = 0
        var previous: Date?
        return points.map { point in
            let isContinuous = previous.map { point.time.timeIntervalSince($0) <= maximumGap } ?? false
            previous = point.time
            guard point.values[.externalPower] == 0, let charge = point.values[.batteryCharge] else {
                (segment, anchor) = ([], 0)
                return FindingSample(time: point.time, value: point.values[.externalPower] == 1 ? 0 : nil)
            }
            if !isContinuous { (segment, anchor) = ([], 0) }
            segment.append((point.time, charge))
            // Anker: der jüngste Punkt, der mindestens ein Fenster zurückliegt.
            while anchor + 1 < segment.count, point.time.timeIntervalSince(segment[anchor + 1].time) >= window {
                anchor += 1
            }
            if anchor > 64 { (segment, anchor) = (Array(segment[anchor...]), 0) }
            let elapsed = point.time.timeIntervalSince(segment[anchor].time)
            guard elapsed >= window else { return FindingSample(time: point.time, value: nil) }
            return FindingSample(time: point.time, value: max(0, (segment[anchor].charge - charge) / elapsed * 3_600))
        }
    }

    private static func findings(of kind: SystemFinding.Kind, series: [FindingSample], subject: SystemFinding.Subject?,
                                 thresholds: FindingThresholds) -> [SystemFinding] {
        let rule = thresholds.rule(for: kind)
        return FindingHysteresis(rule: rule, maximumGap: thresholds.maximumGap).episodes(in: series).map { episode in
            let tone = Self.tone(of: rule, peak: episode.peak)
            return SystemFinding(kind: kind, tone: tone,
                                 reason: reason(for: kind, tone: tone, subject: subject, thresholds: thresholds),
                                 start: episode.start, end: episode.end,
                                 evidence: .init(limit: rule.limit, peak: episode.peak, mean: episode.mean),
                                 subject: subject)
        }
    }

    /// Kritisch ab `critical` der Regel (einschließlich), sonst auffällig.
    static func tone(of rule: FindingRule, peak: Double) -> SystemFinding.Tone {
        rule.critical.map { peak >= $0 } == true ? .critical : .finding
    }

    // MARK: Texte

    /// Grund in einem Satz; nennt die Schwellen aus `thresholds`.
    static func reason(for kind: SystemFinding.Kind, tone: SystemFinding.Tone, subject: SystemFinding.Subject?,
                       thresholds: FindingThresholds) -> String {
        let rule = thresholds.rule(for: kind)
        let duration = AppUsagePresentation.durationText(rule.minimumDuration)
        let limit = PerformancePresentation.percent(rule.limit)
        switch kind {
        case .systemLoad:
            return "CPU insgesamt länger als \(duration) über \(limit) ausgelastet."
        case .processLoad:
            return "\(processName(subject)) belegt länger als \(duration) mehr als \(limit) eines Kerns."
        case .memoryPressure:
            return tone == .critical ? "macOS meldet kritischen Speicherdruck: Der Arbeitsspeicher reicht nicht aus."
                : "macOS meldet erhöhten Speicherdruck und komprimiert oder lagert Speicher aus."
        case .swapGrowth:
            let window = AppUsagePresentation.durationText(thresholds.swapGrowthWindow)
            return "Der Auslagerungsspeicher wächst innerhalb von \(window) um mehr als "
                + "\(TrafficFormat.bytes(UInt64(rule.limit)))."
        case .thermalState:
            return tone == .critical ? "macOS meldet einen kritischen thermischen Zustand und drosselt den Mac."
                : "macOS meldet länger als \(duration) einen erhöhten thermischen Zustand und drosselt gegebenenfalls."
        case .throttling:
            return "Der Mac drosselt: Unter Last laufen die Leistungskerne länger als \(duration) unter "
                + "\(PerformancePresentation.percent(thresholds.throttlingClock)) ihres Höchsttakts, der thermische Druck "
                + "ist erhöht."
        case .diskLoad:
            return "Die Datenträger lesen und schreiben länger als \(duration) zusammen mehr als "
                + "\(TrafficFormat.rate(rule.limit))."
        case .sustainedUpload:
            return "Der Mac sendet länger als \(duration) mehr als \(TrafficFormat.rate(rule.limit)) – möglicherweise "
                + "eine ungewollte Übertragung."
        case .batteryDrain:
            return "Der Akku entlädt sich schneller als \(limit) je Stunde."
        case .exposedService:
            return "\(serviceName(subject)) ist neu aus dem Netz erreichbar."
        case .volumeFull:
            let name = volumeDisplayName(subject).map { "„\($0)“" } ?? "Ein Volume"
            return "\(name) ist zu mehr als \(limit) belegt."
        case .smartFailure:
            let name = volumeDisplayName(subject).map { "Der Datenträger „\($0)“" } ?? "Ein Datenträger"
            return "\(name) meldet einen SMART-Fehler – Daten sichern."
        case .staleSnapshots:
            return "Ein lokaler Time-Machine-Snapshot ist älter als \(daysText(rule.limit)) und belegt weiter Platz."
        case .extensionRisk:
            return "Eine Erweiterung mit Sonderrechten ist auffällig."
        }
    }

    private static func processName(_ subject: SystemFinding.Subject?) -> String {
        guard case .process(_, let name) = subject else { return "Ein Prozess" }
        return displayName(name, generic: "Ein Prozess", otherAccounts: "Ein Prozess eines anderen Kontos")
    }

    private static func serviceName(_ subject: SystemFinding.Subject?) -> String {
        guard case .networkService(_, let name) = subject else { return "Ein Dienst" }
        return displayName(name, generic: "Ein Dienst", otherAccounts: "Ein Dienst eines anderen Kontos")
    }

    /// Name nach der Regel des Wachbuchs: andere Konten ohne Namen, ohne lesbaren Namen allgemein.
    private static func displayName(_ subject: WatchbookSubject?, generic: String, otherAccounts: String) -> String {
        switch subject {
        case .program(let name), .systemProcess(let name): name
        case .otherAccounts: otherAccounts
        case nil: generic
        }
    }
}
