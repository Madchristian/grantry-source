import Foundation

/// Texte des Segments „Prozesse“ (#221): Speicherstatus, Posten, Sammeldialog, SIGKILL-Rückfrage und Ergebnis; dazu
/// der Hinweis auf viele verwaiste Agenten-Bäume (#224).
public enum ProcessCleanupPresentation {
    /// Arbeitsspeicher wie in der Aktivitätsanzeige („36,9 GB“).
    public static func memoryText(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory))
    }

    /// „Arbeitsspeicher 36,9 GB von 64 GB · Swap 4,3 GB von 5,4 GB · Speicherdruck normal · 933 Prozesse“.
    public static func statusLine(_ status: MemoryStatus) -> String {
        var parts: [String] = []
        let total = memoryText(status.physicalBytes)
        parts.append(status.usedBytes.map { "Arbeitsspeicher \(memoryText($0)) von \(total)" } ?? "Arbeitsspeicher \(total)")
        if let used = status.swapUsedBytes, let swapTotal = status.swapTotalBytes {
            parts.append(swapTotal == 0 ? "kein Swap" : "Swap \(memoryText(used)) von \(memoryText(swapTotal))")
        }
        if let pressure = status.pressure { parts.append("Speicherdruck \(pressureText(pressure))") }
        parts.append(status.processCount == 1 ? "1 Prozess" : "\(status.processCount) Prozesse")
        return parts.joined(separator: " · ")
    }

    public static func pressureText(_ pressure: MemoryStatus.Pressure) -> String {
        switch pressure {
        case .normal: "normal"
        case .warning: "erhöht"
        case .critical: "kritisch"
        }
    }

    /// „~/Projekte/app · läuft seit 3 Tagen · 12 Prozesse · 1,2 GB“.
    public static func subtitle(_ tree: AgentProcessTree, now: Date) -> String {
        var parts: [String] = []
        if let workspace = tree.workspace { parts.append((workspace as NSString).abbreviatingWithTildeInPath) }
        parts.append("läuft seit \(age(since: tree.startDate, now: now))")
        parts.append(processCountText(tree.processCount))
        parts.append(memoryText(tree.memoryBytes))
        return parts.joined(separator: " · ")
    }

    /// „gebootet seit 8 Stunden · 230 Prozesse · 12 GB“ (fehlende Angaben entfallen).
    public static func subtitle(_ simulator: BootedSimulator, now: Date) -> String {
        var parts: [String] = []
        if let bootedAt = simulator.bootedAt { parts.append("gebootet seit \(age(since: bootedAt, now: now))") }
        if simulator.processCount > 0 { parts.append(processCountText(simulator.processCount)) }
        parts.append(simulator.memoryBytes.map(memoryText) ?? "Speicher unbekannt")
        return parts.joined(separator: " · ")
    }

    /// Hinweis zu ausgelassenen Bäumen; `nil` ohne solche.
    public static func inUseNote(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 Agenten-Prozessbaum gehört zu einer laufenden Sitzung und wird nicht angeboten."
        default: "\(count) Agenten-Prozessbäume gehören zu laufenden Sitzungen und werden nicht angeboten."
        }
    }

    /// Ein Sammeldialog: je Posten Weg und Speicher.
    public static func confirmation(trees: [AgentProcessTree], simulators: [BootedSimulator]) -> ActionConfirmation {
        let lines = trees.map { tree in
            "\(tree.title): beenden (SIGTERM) – \(memoryText(tree.memoryBytes))"
        } + simulators.map { simulator in
            "Simulator \(simulator.title): \(simulator.shutdownCommand.commandLine)"
        }
        let count = trees.count + simulators.count
        return ActionConfirmation(
            title: count == 1 ? "1 Posten beenden?" : "\(count) Posten beenden?",
            message: lines.joined(separator: "\n"),
            note: "Nicht gesicherte Arbeit in diesen Prozessen geht verloren. Grantry sendet zuerst SIGTERM; was "
                + "danach weiterläuft, beendet es nur nach erneuter Bestätigung sofort (SIGKILL).",
            confirmTitle: "Beenden",
            isDestructive: true
        )
    }

    /// Zweite Bestätigung für die Überlebenden eines SIGTERM.
    public static func forceConfirmation(_ outcomes: [ProcessCleanupOutcome]) -> ActionConfirmation {
        let count = outcomes.map(\.survivors.count).reduce(0, +)
        return ActionConfirmation(
            title: count == 1 ? "1 Prozess sofort beenden (SIGKILL)?" : "\(count) Prozesse sofort beenden (SIGKILL)?",
            message: outcomes.map(\.title).joined(separator: "\n"),
            note: "SIGKILL lässt den Prozessen keine Gelegenheit, aufzuräumen oder Daten zu sichern.",
            confirmTitle: "Sofort beenden",
            isDestructive: true
        )
    }

    /// „2 beendet (1,4 GB Arbeitsspeicher), 1 läuft noch, 1 übersprungen“.
    public static func summary(_ outcomes: [ProcessCleanupOutcome]) -> String {
        let removed = outcomes.filter { $0.result == .removed }
        let running = outcomes.count { !$0.survivors.isEmpty }
        let skipped = outcomes.count { if case .skipped = $0.result { true } else { false } }
        let failed = outcomes.count { if case .failed = $0.result { $0.survivors.isEmpty } else { false } }
        var parts: [String] = []
        if removed.isEmpty {
            parts.append("Nichts beendet")
        } else {
            let memory = removed.compactMap(\.memoryBytes).reduce(0, +)
            parts.append("\(removed.count) beendet" + (memory > 0 ? " (\(memoryText(memory)) Arbeitsspeicher)" : ""))
        }
        if running > 0 { parts.append("\(running) läuft noch") }
        if skipped > 0 { parts.append("\(skipped) übersprungen") }
        if failed > 0 { parts.append("\(failed) fehlgeschlagen") }
        return parts.joined(separator: ", ")
    }

    /// Titel des Hinweises auf viele verwaiste Agenten-Bäume (#224).
    public static let alertTitle = "Viele verwaiste Agenten-Prozesse"

    /// „12 verwaiste Agenten-Prozessbäume belegen 2,4 GB. Unter Aufräumen › Prozesse ansehen – beendet wird nur nach
    /// Bestätigung.“
    public static func alertBody(_ orphans: [AgentProcessTree]) -> String {
        let memory = memoryText(OrphanAgentAlertThreshold.totalMemory(of: orphans))
        let trees = orphans.count == 1
            ? "1 verwaister Agenten-Prozessbaum belegt \(memory)."
            : "\(orphans.count) verwaiste Agenten-Prozessbäume belegen \(memory)."
        return trees + " Unter Aufräumen › Prozesse ansehen – beendet wird nur nach Bestätigung."
    }

    /// Erklärung der Einstellung; Takt und Schwelle aus `OrphanAgentAlerter.interval` und
    /// `OrphanAgentAlertThreshold.standard`.
    public static var alertSettingNote: String {
        let minutes = OrphanAgentAlerter.interval.components.seconds / 60
        let threshold = OrphanAgentAlertThreshold.standard
        return "Liest alle \(minutes) Minuten die Prozessliste und meldet sich, sobald mehr als \(threshold.treeCount) "
            + "verwaiste Agenten-Prozessbäume oder zusammen mehr als \(memoryText(threshold.memoryBytes)) Arbeitsspeicher "
            + "anfallen – erneut erst, wenn zwischendurch aufgeräumt wurde. Grantry beendet dabei nichts; das geht nur "
            + "unter Aufräumen › Prozesse nach Bestätigung."
    }

    private static func processCountText(_ count: Int) -> String {
        count == 1 ? "1 Prozess" : "\(count) Prozesse"
    }

    /// „5 Minuten“, „3 Stunden“, „2 Tagen“ (nach „seit“).
    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<3_600:
            let minutes = max(1, Int(seconds / 60))
            return minutes == 1 ? "1 Minute" : "\(minutes) Minuten"
        case ..<86_400:
            let hours = Int(seconds / 3_600)
            return hours == 1 ? "1 Stunde" : "\(hours) Stunden"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "1 Tag" : "\(days) Tagen"
        }
    }
}
