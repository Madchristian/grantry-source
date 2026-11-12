import Foundation

/// Zustandszeile des Segments „Prozesse“ im Lagebild (LB-4.4, #550; Entwurf LB-4.1, #547, Spec 2026-11-10 § 11.4):
/// Urteil, Schildform, höchstens drei Chips und rechts der Speicherstand. Vor dem ersten Ergebnis offene Schildform statt
/// einer Entwarnung (Korrektur 3); nicht lesbare Quellen geben keine Entwarnung.
public struct ProcessCleanupVerdict: Hashable, Sendable {
    static let maximumItems = 3

    public let title: String
    public let shield: VerdictShield
    public let items: [SystemVerdict.Item]
    public let facts: String

    /// - Parameters:
    ///   - overview: letztes Ergebnis; `nil` vor dem ersten Scan.
    ///   - scanError: Prozesse nicht lesbar.
    ///   - survivorCount: Prozesse, die nach SIGTERM weiterlaufen (`ProcessCleanupModel.forceOffer`).
    public init(overview: ProcessOverview?, isScanning: Bool, scanError: String?, survivorCount: Int) {
        guard let overview else {
            if scanError != nil {
                self.init(title: Self.incompleteTitle, shield: .finding, items: [], facts: "Prozesse nicht lesbar")
            } else if isScanning {
                self.init(title: "Scan läuft", shield: .open, items: [], facts: "Prozesse und Simulatoren")
            } else {
                self.init(title: "Noch nicht gescannt", shield: .open, items: [], facts: "liest nur auf Knopfdruck")
            }
            return
        }
        let trees = overview.agentTrees.orphans.count, simulators = overview.simulators.count
        let isIncomplete = scanError != nil || overview.simulatorError != nil
        let title: String
        if survivorCount > 0 {
            title = survivorCount == 1 ? "1 Prozess reagiert nicht" : "\(survivorCount) Prozesse reagieren nicht"
        } else if isIncomplete {
            title = Self.incompleteTitle
        } else if trees + simulators > 0 {
            title = "\(trees + simulators) Posten aufräumbar"
        } else {
            title = "Ruhig"
        }
        let candidates: [SystemVerdict.Item?] = [
            survivorCount > 0 ? SystemVerdict.Item(text: "\(survivorCount) läuft weiter", tone: .warning) : nil,
            trees > 0
                ? SystemVerdict.Item(text: trees == 1 ? "1 verwaister Agent" : "\(trees) verwaiste Agenten", tone: .warning)
                : nil,
            simulators > 0
                ? SystemVerdict.Item(text: simulators == 1 ? "1 Simulator" : "\(simulators) Simulatoren", tone: .neutral)
                : nil,
            overview.memory.pressure.map(Self.pressureItem),
        ]
        self.init(title: title, shield: title == "Ruhig" ? .calm : .finding,
                  items: Array(candidates.compactMap(\.self).prefix(Self.maximumItems)),
                  facts: ProcessCleanupPresentation.statusFacts(overview.memory))
    }

    private init(title: String, shield: VerdictShield, items: [SystemVerdict.Item], facts: String) {
        self.title = title
        self.shield = shield
        self.items = items
        self.facts = facts
    }

    private static let incompleteTitle = "Nicht vollständig gelesen"

    private static func pressureItem(_ pressure: MemoryStatus.Pressure) -> SystemVerdict.Item {
        let tone: PresentationTone = switch pressure {
        case .normal: .positive
        case .warning: .warning
        case .critical: .critical
        }
        return SystemVerdict.Item(text: "Druck \(ProcessCleanupPresentation.pressureText(pressure))", tone: tone)
    }
}

/// Texte der Fundliste, Aktionsleiste und Ausgänge des Segments „Prozesse“ im Lagebild (#550).
extension ProcessCleanupPresentation {
    /// Stand des letzten Scans neben dem Umschalter.
    public struct ScanState: Hashable, Sendable {
        public let title: String
        public let detail: String
        public let isComplete: Bool
    }

    public static func scanState(_ overview: ProcessOverview) -> ScanState {
        overview.simulatorError == nil
            ? ScanState(title: "Scan vollständig", detail: "Prozesse und Simulatoren gelesen", isComplete: true)
            : ScanState(title: "Scan unvollständig", detail: "Simulatoren nicht lesbar", isComplete: false)
    }

    /// Speicher eines Simulators rechts in der Zeile; „–“, wenn unbekannt.
    public static func sizeText(_ simulator: BootedSimulator) -> String {
        simulator.memoryBytes.map(memoryText) ?? "–"
    }

    /// Summe der Speicher-Angaben (unbekannte zählen nicht).
    public static func memoryText(of trees: [AgentProcessTree], simulators: [BootedSimulator] = []) -> String {
        memoryText(trees.map(\.memoryBytes).reduce(0, +) + simulators.compactMap(\.memoryBytes).reduce(0, +))
    }

    /// Umfang in der Aktionsleiste: „Ausgewählt: 2 Agenten-Bäume · 1 Simulator · 7 Prozesse · 1,3 GB“.
    public static func selectionScope(trees: [AgentProcessTree], simulators: [BootedSimulator]) -> String {
        guard !trees.isEmpty || !simulators.isEmpty else { return "Nichts ausgewählt" }
        var parts: [String] = []
        if !trees.isEmpty { parts.append(trees.count == 1 ? "1 Agenten-Baum" : "\(trees.count) Agenten-Bäume") }
        if !simulators.isEmpty { parts.append(simulators.count == 1 ? "1 Simulator" : "\(simulators.count) Simulatoren") }
        let processes = trees.map(\.processCount).reduce(0, +) + simulators.map(\.processCount).reduce(0, +)
        if processes > 0 { parts.append(processCountText(processes)) }
        parts.append(memoryText(of: trees, simulators: simulators))
        return "Ausgewählt: " + parts.joined(separator: " · ")
    }

    /// Prozess eines aufgeklappten Agenten-Baums rechts neben dem Namen: „PID 48211 · 512 MB“.
    public static func memberValue(_ member: ProcessEntry) -> String {
        "PID \(member.pid) · " + (member.memoryBytes.map(memoryText) ?? "–")
    }

    /// Ausgang eines Postens als Zustandschip.
    public static func outcomeStatus(_ outcome: ProcessCleanupOutcome) -> SystemVerdict.Item {
        if !outcome.survivors.isEmpty { return SystemVerdict.Item(text: "läuft weiter", tone: .warning) }
        return switch outcome.result {
        case .removed: SystemVerdict.Item(text: "beendet", tone: .positive)
        case .skipped: SystemVerdict.Item(text: "übersprungen", tone: .neutral)
        case .failed: SystemVerdict.Item(text: "fehlgeschlagen", tone: .critical)
        }
    }

    /// Grund unter dem Posten; `nil` beim Erfolg.
    public static func outcomeReason(_ outcome: ProcessCleanupOutcome) -> String? {
        switch outcome.result {
        case .removed: nil
        case .skipped(let reason), .failed(let reason): reason
        }
    }

    /// Ton des Ergebnis-Banners: alles beendet positiv, Überlebende oder Fehler auffällig, sonst neutral.
    public static func resultTone(_ outcomes: [ProcessCleanupOutcome]) -> PresentationTone {
        let hasProblem = outcomes.contains { outcome in
            if case .failed = outcome.result { true } else { !outcome.survivors.isEmpty }
        }
        if hasProblem { return .warning }
        return outcomes.allSatisfy { $0.result == .removed } ? .positive : .neutral
    }

    /// Satz unter dem Ergebnis: welche Posten nach SIGTERM weiterlaufen; sonst leer.
    public static func resultMessage(_ outcomes: [ProcessCleanupOutcome]) -> String {
        let running = outcomes.filter { !$0.survivors.isEmpty }.map { "„\($0.title)“" }
        switch running.count {
        case 0: return ""
        case 1: return "\(running[0]) läuft nach SIGTERM weiter."
        default: return running.joined(separator: ", ") + " laufen nach SIGTERM weiter."
        }
    }
}
