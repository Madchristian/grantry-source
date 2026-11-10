import Foundation

/// Laufende Befunde für Lage- und Zustandszeile des Task-Managers: sammelt je Takt einen Messpunkt (`WatchbookPoint`)
/// und die Prozesslast, dazu die Sensor-Messungen des Helpers für die Drosselung, über `span` und wertet alles mit
/// `FindingRules` aus – dieselben Regeln, Schwellen und Texte wie das Wachbuch. Eine Pause (verdeckter Task-Manager)
/// ist eine Lücke: Sie beginnt und beendet keinen Befund. Datenträger-Befunde kommen aus dem Volume-Inventar nach einem
/// Scan und gelten bis zur nächsten Prüfung, unabhängig vom Takt.
public struct FindingTracker: Sendable {
    /// Laufende Befunde (ohne Ende): kritische zuerst, sonst nach Beginn.
    public private(set) var findings: [SystemFinding] = []

    let thresholds: FindingThresholds
    let span: TimeInterval
    private var points: [WatchbookPoint] = []
    private var processSamples: [ProcessLoadSample] = []
    private var throttlingSamples: [ThrottlingSample] = []
    /// Laufende Befunde aus den Takten bzw. aus den Sensor-Messungen; jede Seite wird nur bei eigenen Daten neu
    /// ausgewertet.
    private var tickFindings: [SystemFinding] = []
    private var throttlingFindings: [SystemFinding] = []
    private var storageFindings: [SystemFinding] = []

    public init(thresholds: FindingThresholds = .standard,
                span: TimeInterval = TimeInterval(SampleHistory.span.components.seconds)) {
        self.thresholds = thresholds
        self.span = span
    }

    /// Trägt einen Takt ein und wertet neu aus; Punkte älter als `span` entfallen.
    /// - Parameter thermalState: `ProcessInfo.thermalState`, `nil`, wenn nicht gelesen.
    public mutating func record(_ snapshot: TaskManagerSnapshot, at time: Date,
                                thermalState: ProcessInfo.ThermalState?, currentUID: UInt32) {
        points.append(WatchbookPoint(time: time, snapshot: snapshot, currentUID: currentUID,
                                     thermalState: thermalState, power: nil))
        processSamples.append(ProcessLoadSample(time: time, snapshot: snapshot, currentUID: currentUID,
                                                above: thresholds.processLoad.limit))
        let oldest = time.addingTimeInterval(-span)
        points.removeAll { $0.time < oldest }
        processSamples.removeAll { $0.time < oldest }
        tickFindings = (FindingRules.findings(in: points, thresholds: thresholds)
            + FindingRules.processFindings(in: processSamples, thresholds: thresholds)).filter(\.isOngoing)
        publish(at: time)
    }

    /// Trägt eine Sensor-Messung des Helpers ein (Regel „Drosselung“); Messungen älter als `span` entfallen.
    public mutating func record(_ sample: ThrottlingSample) {
        throttlingSamples.append(sample)
        let oldest = sample.time.addingTimeInterval(-span)
        throttlingSamples.removeAll { $0.time < oldest }
        throttlingFindings = FindingRules.throttlingFindings(in: throttlingSamples, thresholds: thresholds)
            .filter(\.isOngoing)
        publish(at: sample.time)
    }

    /// Trägt das Volume-Inventar einer Prüfung ein (TM-15.5); laufende Datenträger-Befunde behalten ihren Beginn.
    public mutating func record(_ inventory: VolumeInventory, at time: Date) {
        storageFindings = FindingRules.storageFindings(in: inventory, at: time, continuing: storageFindings,
                                                       thresholds: thresholds)
        publish(at: time)
    }

    /// Eine Drosselung läuft nur mit frischer Sensor-Messung weiter: Stoppen die Sensoren (Helper aus, anderer Tab), ist
    /// sie nicht mehr gemessen statt „läuft noch“.
    private mutating func publish(at time: Date) {
        let isFresh = throttlingSamples.last.map { time.timeIntervalSince($0.time) <= thresholds.maximumGap } ?? false
        findings = (tickFindings + (isFresh ? throttlingFindings : []) + storageFindings).sorted { first, second in
            (first.tone == .critical ? 0 : 1, first.start) < (second.tone == .critical ? 0 : 1, second.start)
        }
    }
}
