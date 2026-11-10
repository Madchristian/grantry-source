import Foundation

/// Schwelle und Hysterese einer Regel: Ein Befund beginnt, wenn der Wert ohne Lücke mindestens `minimumDuration` lang
/// über `limit` liegt, und endet, wenn er danach ohne Lücke mindestens `quietDuration` lang nicht mehr darüber liegt.
public struct FindingRule: Hashable, Sendable {
    /// Aktiv, solange der Wert **über** dieser Grenze liegt (Stufen: über 0 = erhöht).
    public var limit: Double
    /// Ab diesem Wert (einschließlich) ist der Befund kritisch; `nil`, wenn die Regel keinen kritischen Ton kennt.
    public var critical: Double?
    public var minimumDuration: TimeInterval
    public var quietDuration: TimeInterval

    public init(limit: Double, critical: Double? = nil, minimumDuration: TimeInterval, quietDuration: TimeInterval) {
        self.limit = limit
        self.critical = critical
        self.minimumDuration = minimumDuration
        self.quietDuration = quietDuration
    }
}

/// Alle Schwellen der Befundregeln an einer Stelle (Spec 2026-11-08 §4.3, Startsatz §5.1). Einheiten wie im Wachbuch
/// (`WatchbookMetric`): Anteile 0…1, Byte und Byte/s, Stufen als Zahl.
public struct FindingThresholds: Hashable, Sendable {
    /// CPU gesamt über 80 % für 2 min.
    public var systemLoad = FindingRule(limit: 0.8, minimumDuration: 120, quietDuration: 60)
    /// Ein Prozess über 90 % **eines Kerns** für 5 min.
    public var processLoad = FindingRule(limit: 0.9, minimumDuration: 300, quietDuration: 60)
    /// Speicherdruck erhöht (1) oder kritisch (2) für 1 min.
    public var memoryPressure = FindingRule(limit: 0, critical: 2, minimumDuration: 60, quietDuration: 60)
    /// Swap-Zuwachs über 2 GB innerhalb von `swapGrowthWindow`; das Fenster selbst ist die Mindestdauer.
    public var swapGrowth = FindingRule(limit: 2_000_000_000, minimumDuration: 0, quietDuration: 60)
    public var swapGrowthWindow: TimeInterval = 600
    /// Thermischer Zustand mäßig (1) oder ernst (2) länger als 5 min; kritisch (3) ist kritisch.
    public var thermalState = FindingRule(limit: 0, critical: 3, minimumDuration: 300, quietDuration: 60)
    /// Drosselung (TM-14.2): Takt der Leistungscluster unter `throttlingClock` des Höchsttakts bei über
    /// `throttlingLoad` Last und thermischem Druck ab `throttlingPressure`, für 1 min. Der Wert der Regel ist der
    /// Abschlag vom Höchsttakt (1 − Anteil), solange alle Bedingungen gelten, sonst 0 (`FindingRules.throttlingSeries`).
    public var throttling = FindingRule(limit: 0, minimumDuration: 60, quietDuration: 60)
    public var throttlingClock = 0.7
    public var throttlingLoad = 0.6
    public var throttlingPressure = ThermalPressureLevel.moderate
    /// Datenträger gesamt (lesen und schreiben) über 100 MB/s für 5 min.
    public var diskLoad = FindingRule(limit: 100_000_000, minimumDuration: 300, quietDuration: 60)
    /// Gesendet über 5 MB/s für 5 min – Hinweis auf eine ungewollte Übertragung.
    public var sustainedUpload = FindingRule(limit: 5_000_000, minimumDuration: 300, quietDuration: 60)
    /// Entladung über 20 % je Stunde, gemessen über `batteryDrainWindow` am Akku, für 5 min.
    public var batteryDrain = FindingRule(limit: 0.2, minimumDuration: 300, quietDuration: 300)
    public var batteryDrainWindow: TimeInterval = 600
    /// Neuer aus dem Netz erreichbarer Dienst: eine Regel über den Verlauf statt über Messreihen – jeder solche Dienst
    /// sofort, ohne Hysterese (`FindingRules.exposedServiceFindings`).
    public var exposedService = FindingRule(limit: 0, minimumDuration: 0, quietDuration: 0)
    /// Datenträger (TM-15.5): Zustände aus dem Volume-Inventar, das nach einem Scan gelesen wird – ohne Hysterese, ein
    /// Befund gilt, bis eine vollständige Prüfung ihn widerlegt (`FindingRules.storageFindings`).
    /// Volume über 90 % belegt; was macOS bei Bedarf selbst freigibt, zählt als frei.
    public var volumeFull = FindingRule(limit: 0.9, minimumDuration: 0, quietDuration: 0)
    /// SMART-Fehler (1) ist immer kritisch.
    public var smartFailure = FindingRule(limit: 0, critical: 1, minimumDuration: 0, quietDuration: 0)
    /// Ältester lokaler Snapshot älter als 7 Tage (Sekunden); macOS entfernt sie sonst nach etwa einem Tag.
    public var staleSnapshots = FindingRule(limit: 7 * 86_400, minimumDuration: 0, quietDuration: 0)
    /// Auffällige Erweiterung: eine Regel über das Inventar (`SystemFinding.extensionFindings`) – sofort, ohne Hysterese.
    public var extensionRisk = FindingRule(limit: 0, minimumDuration: 0, quietDuration: 0)
    /// Größter Abstand zweier Messpunkte, die noch als lückenlos gelten; wie die Abdeckung eines Wachbuch-Punkts.
    public var maximumGap: TimeInterval = WatchbookPoint.maximumCoverage

    public static let standard = FindingThresholds()

    public init() {}

    public func rule(for kind: SystemFinding.Kind) -> FindingRule {
        switch kind {
        case .systemLoad: systemLoad
        case .processLoad: processLoad
        case .memoryPressure: memoryPressure
        case .swapGrowth: swapGrowth
        case .thermalState: thermalState
        case .throttling: throttling
        case .diskLoad: diskLoad
        case .sustainedUpload: sustainedUpload
        case .batteryDrain: batteryDrain
        case .exposedService: exposedService
        case .volumeFull: volumeFull
        case .smartFailure: smartFailure
        case .staleSnapshots: staleSnapshots
        case .extensionRisk: extensionRisk
        }
    }
}
