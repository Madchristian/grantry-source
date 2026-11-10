import Foundation

/// Urteil über den Zustand des Macs für Lage- und Zustandszeile des Task-Managers (Gestaltung „Lagebild“, Entscheidung
/// E9): ein Satz statt einer Statusleiste. Grundlage sind die laufenden Befunde aus `FindingRules` (`FindingTracker`) –
/// dieselben Regeln, Schwellen und Texte wie das Wachbuch –, nie ein einzelner Messwert.
public struct SystemVerdict: Hashable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case calm, finding, critical

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Zustand als Chip: Text und Ton (`positive`, `neutral`, `warning` = auffällig, `critical`).
    public struct Item: Hashable, Sendable {
        public let text: String
        public let tone: PresentationTone

        public init(text: String, tone: PresentationTone) {
            self.text = text
            self.tone = tone
        }
    }

    /// Prozess mit Dauerlast.
    public struct ProcessFinding: Hashable, Sendable, Identifiable {
        public let key: ProcessKey
        public let name: String
        /// Grund des Befunds (`SystemFinding.reason`).
        public let reason: String
        /// Aktuelle Last als Anteil an allen Kernen (wie `ProcessMeasurement.cpuLoad`).
        public let cpuLoad: Double

        public var id: ProcessKey { key }
    }

    public let level: Level
    public let title: String
    public let reason: String
    public let items: [Item]
    public let processFindings: [ProcessFinding]
    /// „Takt 1 s · 642 Prozesse · 2.814 Threads · Laufzeit 3:04:17“.
    public let facts: String
}

public enum SystemVerdictPresentation {
    static let maximumProcessFindings = 3
    /// Befunde, für die der Energiesparmodus ein Grund ist: Er senkt Takt und Leistung.
    private static let lowPowerReasonKinds: Set<SystemFinding.Kind> = [.systemLoad, .processLoad, .thermalState,
                                                                       .throttling]

    /// Thermischer Zustand und Energiesparmodus kommen mit dem Takt (`TaskManagerSnapshot.thermal`).
    /// - Parameter findings: laufende Befunde (`TaskManagerModel.findings`); beendete zählen nicht.
    public static func verdict(snapshot: TaskManagerSnapshot, findings: [SystemFinding], interval: String,
                               uptime: TimeInterval) -> SystemVerdict {
        let ongoing = findings.filter(\.isOngoing)
        let processes = processFindings(ongoing, snapshot: snapshot)
        let memoryFinding = ongoing.first { $0.kind == .memoryPressure }
        let thermalFinding = ongoing.first { $0.kind == .thermalState }
        let others = ongoing.filter { ![.processLoad, .memoryPressure, .thermalState].contains($0.kind) }
        let lowPower = snapshot.thermal?.isLowPowerModeEnabled == true
        let items = [processItem(processes), snapshot.memory?.pressure.map { memoryItem($0, finding: memoryFinding) },
                     snapshot.thermal.map { thermalItem($0.state, finding: thermalFinding) },
                     lowPower ? SystemVerdict.Item(text: String(localized: "Energiesparmodus"), tone: .neutral) : nil]
            .compactMap(\.self)
            + others.map { SystemVerdict.Item(text: title(of: $0, processCount: 0), tone: tone(of: $0)) }
        let lead = leading(ongoing)
        var reason = lead?.reason ?? calmReason(snapshot)
        if lowPower, lead.map({ lowPowerReasonKinds.contains($0.kind) }) ?? true {
            reason += " " + String(localized: "Der Energiesparmodus ist an und senkt Takt und Leistung.")
        }
        return SystemVerdict(level: ongoing.map(level(of:)).max() ?? .calm,
                             title: lead.map { title(of: $0, processCount: processes.count) } ?? calmTitle(snapshot),
                             reason: reason,
                             items: items, processFindings: processes,
                             facts: OverviewPresentation.status(for: snapshot, interval: interval, uptime: uptime)
                                 .joined(separator: " · "))
    }

    /// Leerzustand der Liste „Auffällig“, mit den Schwellen der Regel.
    public static func quietProcessesText(thresholds: FindingThresholds = .standard) -> String {
        let rule = thresholds.processLoad
        let duration = AppUsagePresentation.durationText(rule.minimumDuration)
        let limit = PerformancePresentation.percent(rule.limit)
        return String(localized: "Kein Prozess belegt länger als \(duration) mehr als \(limit) eines Kerns.")
    }

    /// Prozesse mit laufender Dauerlast, die noch laufen; stärkste zuerst.
    static func processFindings(_ findings: [SystemFinding], snapshot: TaskManagerSnapshot) -> [SystemVerdict.ProcessFinding] {
        let running = Dictionary(snapshot.processes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let processes = findings.compactMap { finding -> SystemVerdict.ProcessFinding? in
            guard case .process(let key, _) = finding.subject, let process = running[key] else { return nil }
            return SystemVerdict.ProcessFinding(key: key, name: process.name, reason: finding.reason,
                                                cpuLoad: process.cpuLoad ?? 0)
        }
        return Array(processes.sorted { ($0.cpuLoad, $1.key.pid) > ($1.cpuLoad, $0.key.pid) }.prefix(maximumProcessFindings))
    }

    /// Der Befund, der Titel und Grund bestimmt: kritische zuerst, dann Dauerlast von Prozessen, sonst der älteste.
    private static func leading(_ findings: [SystemFinding]) -> SystemFinding? {
        findings.min { first, second in
            (rank(first), first.start) < (rank(second), second.start)
        }
    }

    private static func rank(_ finding: SystemFinding) -> Int {
        if finding.tone == .critical { return 0 }
        return finding.kind == .processLoad ? 1 : 2
    }

    private static func level(of finding: SystemFinding) -> SystemVerdict.Level {
        finding.tone == .critical ? .critical : .finding
    }

    private static func tone(of finding: SystemFinding) -> PresentationTone {
        finding.tone == .critical ? .critical : .warning
    }

    /// Kurzer Titel eines Befunds für Lagezeile und Chip.
    private static func title(of finding: SystemFinding, processCount: Int) -> String {
        let critical = finding.tone == .critical
        switch finding.kind {
        case .processLoad:
            return processCount > 1 ? String(localized: "\(processCount) Prozesse auffällig")
                : String(localized: "1 Prozess auffällig")
        case .memoryPressure: return critical ? String(localized: "Speicher kritisch") : String(localized: "Speicher wird knapp")
        case .thermalState: return critical ? String(localized: "Mac überhitzt") : String(localized: "Mac wird warm")
        case .throttling: return String(localized: "Mac drosselt")
        case .systemLoad: return String(localized: "Dauerhaft hohe Last")
        case .swapGrowth: return String(localized: "Auslagerung wächst")
        case .diskLoad: return String(localized: "Datenträger stark belastet")
        case .sustainedUpload: return String(localized: "Anhaltender Upload")
        case .batteryDrain: return String(localized: "Akku entlädt sich schnell")
        case .exposedService: return String(localized: "Neuer Dienst aus dem Netz erreichbar")
        case .volumeFull: return String(localized: "Volume fast voll")
        case .smartFailure: return String(localized: "SMART-Fehler")
        case .staleSnapshots: return String(localized: "Alte lokale Snapshots")
        case .extensionRisk: return String(localized: "Erweiterung auffällig")
        }
    }

    private static func processItem(_ findings: [SystemVerdict.ProcessFinding]) -> SystemVerdict.Item? {
        guard !findings.isEmpty else { return nil }
        let text = findings.count == 1 ? String(localized: "1 Prozess auffällig")
            : String(localized: "\(findings.count) Prozesse auffällig")
        return SystemVerdict.Item(text: text, tone: .warning)
    }

    /// Zustand des Speicherdrucks; auffällig oder kritisch erst mit Befund, vorher neutral.
    private static func memoryItem(_ pressure: MemoryStatus.Pressure, finding: SystemFinding?) -> SystemVerdict.Item {
        let text = switch pressure {
        case .normal: String(localized: "Speicherdruck normal")
        case .warning: String(localized: "Speicherdruck erhöht")
        case .critical: String(localized: "Speicherdruck kritisch")
        }
        return SystemVerdict.Item(text: text, tone: finding.map(tone(of:)) ?? (pressure == .normal ? .positive : .neutral))
    }

    /// Thermischer Zustand; auffällig oder kritisch erst mit Befund, vorher neutral.
    private static func thermalItem(_ state: ProcessInfo.ThermalState, finding: SystemFinding?) -> SystemVerdict.Item {
        let text = switch state {
        case .nominal: String(localized: "Thermik normal")
        case .fair: String(localized: "Thermik mäßig")
        case .serious: String(localized: "Thermik ernst")
        case .critical: String(localized: "Thermik kritisch")
        @unknown default: String(localized: "Thermik unbekannt")
        }
        return SystemVerdict.Item(text: text, tone: finding.map(tone(of:)) ?? (state == .nominal ? .positive : .neutral))
    }

    private static func calmTitle(_ snapshot: TaskManagerSnapshot) -> String {
        (snapshot.cpu?.total ?? 0) >= 0.7 ? String(localized: "Hohe Last, ohne Befund") : String(localized: "Ruhig")
    }

    private static func calmReason(_ snapshot: TaskManagerSnapshot) -> String {
        let cpu = PerformancePresentation.percent(snapshot.cpu?.total)
        let memory = PerformancePresentation.percent(snapshot.memory.flatMap(PerformancePresentation.usedShare))
        return String(localized: "CPU \(cpu), Arbeitsspeicher \(memory) belegt – nichts fällt auf.")
    }
}
