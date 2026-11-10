import GrantryShared

/// Prüft nach einem Signal alle `pollInterval`, höchstens `gracePeriod` lang, ob Prozesse enden. Beendet ist ein Prozess
/// erst, wenn seine PID fehlt oder neu vergeben ist (`ProcessInspecting.hasEnded`); ein exec oder Benutzerwechsel unter
/// derselben PID und Startzeit, eine gerade nicht bestätigte Identität (`process(_:)` liefert `nil`, etwa nach einem
/// exec zwischen den Token-Lesungen) oder ein nicht feststellbarer Zustand gelten nicht als Ende.
struct ProcessEndWaiter: Sendable {
    let inspector: any ProcessInspecting
    let clock: any Clock<Duration>
    let gracePeriod: Duration
    let pollInterval: Duration

    /// Prozesse aus `processes`, die nach höchstens `gracePeriod` noch laufen.
    func stillRunning(_ processes: [RunningProcess]) async -> [RunningProcess] {
        var running = processes.filter { !hasEnded($0) }
        var polls = Int((gracePeriod / pollInterval).rounded(.up))
        while !running.isEmpty, polls > 0 {
            polls -= 1
            do { try await clock.sleep(for: pollInterval) } catch { break }
            running = running.filter { !hasEnded($0) }
        }
        return running
    }

    private func hasEnded(_ process: RunningProcess) -> Bool {
        inspector.hasEnded(process.pid, startedAt: process.startTime)
    }
}
