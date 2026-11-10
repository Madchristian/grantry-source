/// Eine Zeile der Baumansicht im Tab „Details“ (Spec 2026-11-06 §6, Stufe 4).
public struct ProcessTreeLine: Hashable, Sendable, Identifiable {
    public let row: ProcessDetailRow
    /// Einrückungstiefe; Wurzeln 0.
    public let depth: Int
    /// Direkte Kinder in der Ansicht, auch wenn die Zeile zugeklappt ist.
    public let childCount: Int
    public let isExpanded: Bool

    public var id: String { row.id }
    public var hasChildren: Bool { childCount > 0 }
}

/// Baut die Zeilen der Baumansicht aus den Eltern-PIDs (rein, je Takt neu). Geschwister behalten die Reihenfolge der
/// übergebenen Zeilen, also die Sortierung des Tabs. Wurzel ist jede Zeile ohne sichtbaren Elternprozess: `launchd`,
/// `kernel_task` (Eltern-PID gleich eigener PID) und bei einer Suche Treffer, deren Eltern nicht passen. macOS hängt
/// verwaiste Prozesse an `launchd` um; eine Eltern-PID zeigt deshalb nie auf einen beendeten Prozess, eine Prüfung der
/// Startzeit ist nicht nötig.
public enum ProcessTree {
    /// Ohne Einrückung, wie die flache Tabelle.
    public static func flat(_ rows: [ProcessDetailRow]) -> [ProcessTreeLine] {
        rows.map { ProcessTreeLine(row: $0, depth: 0, childCount: 0, isExpanded: false) }
    }

    /// - Parameter collapsed: IDs zugeklappter Zeilen; ihre Nachkommen entfallen.
    public static func lines(_ rows: [ProcessDetailRow], collapsed: Set<String>) -> [ProcessTreeLine] {
        let pids = Set(rows.map(\.process.key.pid))
        var children: [Int32: [ProcessDetailRow]] = [:]
        var roots: [ProcessDetailRow] = []
        for row in rows {
            let parent = row.process.parentPID
            if parent != row.process.key.pid, pids.contains(parent) {
                children[parent, default: []].append(row)
            } else {
                roots.append(row)
            }
        }
        var lines: [ProcessTreeLine] = []
        var reached: Set<String> = []
        func visit(_ row: ProcessDetailRow, depth: Int, isShown: Bool) {
            guard reached.insert(row.id).inserted else { return }
            let kids = children[row.process.key.pid] ?? []
            let isExpanded = !collapsed.contains(row.id)
            if isShown {
                lines.append(ProcessTreeLine(row: row, depth: depth, childCount: kids.count, isExpanded: isExpanded))
            }
            for kid in kids { visit(kid, depth: depth + 1, isShown: isShown && isExpanded) }
        }
        for root in roots { visit(root, depth: 0, isShown: true) }
        // Ringe aus Eltern-PIDs (nur bei widersprüchlichen Messungen denkbar) erreicht keine Wurzel: dann oben anhängen.
        for row in rows where !reached.contains(row.id) { visit(row, depth: 0, isShown: true) }
        return lines
    }
}
