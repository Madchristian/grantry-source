import AppKit
import ManagerKit
import os

/// Sorgt dafür, dass nur eine Instanz der App je Ablageort läuft (gleiche Bundle-ID, gleich welcher Ort).
///
/// Maßgeblich ist die `InstanceLock`-Sperre im Ablageort: Wer sie hält, läuft. Beendet sich der Halter gerade (etwa
/// während er noch Aktionen abschließt), wartet eine neue Instanz auf die Freigabe, statt an ihn zu übergeben. Nur
/// wenn die Sperrdatei nicht nutzbar ist, entscheidet allein `InstanceArbitration`.
@MainActor
enum SingleInstance {
    nonisolated private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "instance")

    /// Frist, die das Übergeben an die laufende Instanz höchstens dauern darf.
    private static let handOverTimeout: DispatchTimeInterval = .seconds(5)
    /// Frist, auf eine sich beendende Instanz zu warten (sie schließt laufende Aktionen noch ab).
    private static let terminatingHolderTimeout: Duration = .seconds(60)

    /// Gehaltene Sperre; lebt bis zum Ende des Prozesses.
    private static var lock: InstanceLock?

    /// Beansprucht `storage` für diese Instanz. `false`, wenn eine andere Instanz ihn nutzt – dann ist sie nach vorn
    /// geholt, und dieser Prozess soll enden.
    static func claim(_ storage: StorageLocation) -> Bool {
        let acquisition: InstanceLock.Acquisition
        do {
            acquisition = try InstanceLock.acquire(at: storage.instanceLockURL)
        } catch {
            logger.error("Instanzsperre nicht nutzbar: \(error.localizedDescription, privacy: .public)")
            return claimByArbitration()
        }
        switch acquisition {
        case .acquired(let lock):
            self.lock = lock
            return true
        case .held(byTerminatingInstance: true):
            logger.notice("Vorherige Instanz beendet sich noch; warte auf ihre Sperre")
            if let lock = try? InstanceLock.acquire(at: storage.instanceLockURL, waitingUpTo: terminatingHolderTimeout) {
                self.lock = lock
                return true
            }
            return false
        case .held(byTerminatingInstance: false):
            let others = otherInstances()
            if let running = others.toDeferTo ?? others.all.first { handOver(to: running) }
            return false
        }
    }

    /// Vermerkt in der Sperre, dass sich diese Instanz beendet (beim Beenden der App).
    static func markTerminating() {
        do {
            try lock?.markTerminating()
        } catch {
            logger.error("Beenden nicht in der Instanzsperre vermerkt: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ohne Sperre: weicht, wenn `InstanceArbitration` einer anderen Instanz den Vortritt gibt.
    private static func claimByArbitration() -> Bool {
        guard let running = otherInstances().toDeferTo else { return true }
        handOver(to: running)
        return false
    }

    /// Andere laufende Instanzen und die, der diese laut `InstanceArbitration` weichen muss.
    private static func otherInstances() -> (all: [NSRunningApplication], toDeferTo: NSRunningApplication?) {
        let current = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier else { return ([], nil) }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
        let winner = InstanceArbitration.instance(toDeferTo: others.map(\.instance), current: current.instance)
        return (others, winner.flatMap { winner in others.first { $0.processIdentifier == winner.processIdentifier } })
    }

    /// Holt die laufende Instanz nach vorn und lässt sie ihr Hauptfenster öffnen: Das erneute Öffnen ihres Bundles
    /// schickt ihr ein „reopen“-Ereignis, wie ein Klick aufs Dock-Symbol. Wartet höchstens `handOverTimeout`.
    static func handOver(to running: NSRunningApplication) {
        logger.notice("Grantry läuft bereits (PID \(running.processIdentifier)); diese Instanz beendet sich")
        guard let bundleURL = running.bundleURL else {
            running.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let finished = DispatchSemaphore(value: 0)
        // Der Abschluss läuft auf einer nebenläufigen Warteschlange; das Warten blockiert ihn daher nicht.
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                logger.error("Laufende Instanz nicht aktiviert: \(error.localizedDescription, privacy: .public)")
            }
            finished.signal()
        }
        if finished.wait(timeout: .now() + handOverTimeout) == .timedOut {
            running.activate()
        }
    }
}

private extension NSRunningApplication {
    var instance: InstanceArbitration.Instance {
        InstanceArbitration.Instance(processIdentifier: processIdentifier, launchDate: launchDate)
    }
}
