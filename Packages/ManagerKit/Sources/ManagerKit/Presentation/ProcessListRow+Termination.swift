/// Was „Task beenden“ für eine Zeile des Prozess-Tabs träfe (Spec 2026-11-06 §2).
extension ProcessListRow {
    /// Die Prozesse der Zeile; bei Gruppenköpfen leer.
    private var measuredProcesses: [ProcessMeasurement] {
        switch kind {
        case .group: []
        case .entry(let entry, _): entry.processes
        case .child(let process): [process]
        }
    }

    /// `nil` für Gruppenköpfe. Prozesse anderer Benutzer nur mit `allowingForeign` (Helper, TM9) und nur einzeln: Jeder
    /// fragt nach dem Kennwort, eine App mit vielen fremden Helfern hieße viele Dialoge.
    public func terminationCandidate(currentUID: UInt32, allowingForeign: Bool = false) -> TaskTerminationCandidate? {
        let processes = measuredProcesses
        let own = processes.filter { $0.uid == currentUID }
        if !own.isEmpty, own.count == processes.count {
            return TaskTerminationCandidate(name: title, keys: own.map(\.key))
        }
        guard allowingForeign, processes.count == 1 else { return nil }
        return TaskTerminationCandidate(name: title, keys: processes.map(\.key))
    }

    /// Ob die Zeile Prozesse anderer Benutzer enthält: Aktionen daran gehen an den Helper und fragen nach dem
    /// Administratorkennwort.
    public func includesForeignProcess(currentUID: UInt32) -> Bool {
        measuredProcesses.contains { $0.uid != currentUID }
    }

    /// Warum „Task beenden“ für die Zeile gesperrt ist, obwohl sie Prozesse anderer Benutzer enthält (mehrere Prozesse,
    /// darunter fremde: Zeile aufklappen). `nil`, wenn sie beendbar ist oder keinen fremden Prozess enthält. Gilt für
    /// jede Zeile, nicht nur für die Gruppe „System“: Auch eine App mit einem Helfer unter root enthält Fremde.
    public func foreignTerminationNote(currentUID: UInt32) -> String? {
        guard includesForeignProcess(currentUID: currentUID),
              terminationCandidate(currentUID: currentUID, allowingForeign: true) == nil else { return nil }
        return TaskTerminationCandidate.foreignProcessNote
    }
}
