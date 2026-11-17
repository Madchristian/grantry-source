import Foundation

/// Abbrechbarer Scan, dessen Arbeit auf einer seriellen Queue blockiert (`BlockingWorkQueue`, #611): Ein Abbruch verwirft
/// das Ergebnis sofort, beendet die Arbeit aber nicht vor ihrem Ende. Ein neuer Lauf wartet deshalb, bis der vorige –
/// auch ein abgebrochener – tatsächlich fertig ist, bevor er seine Arbeit einreicht; ersetzte Läufe reichen gar keine ein.
/// So stauen wiederholtes Abbrechen und Neustarten keine Aufträge auf der Queue an, und ein Neustart hängt nie länger als
/// die schon laufende Arbeit (docs/entwicklungs-gotchas.md, technische Grenzen).
@MainActor
public final class SerialScanRunner {
    /// Letzter gestarteter Lauf; bleibt nach einem Abbruch stehen, damit der nächste auf sein Ende wartet.
    private var latest: Task<Void, Never>?
    private var run = 0
    /// Ein Lauf ist gestartet und weder fertig noch abgebrochen.
    public private(set) var isRunning = false

    public init() {}

    /// Startet `operation`, sobald der vorige Lauf zu Ende ist (ein laufender wird dafür abgebrochen). `onFinish` erhält
    /// das Ergebnis nur, wenn dieser Lauf weder abgebrochen noch ersetzt wurde. `operation` sollte auf Abbruch achten,
    /// damit sie nach einem Abbruch keine weiteren Schritte beginnt.
    public func start<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value,
                                       onFinish: @escaping @MainActor (Value) -> Void) {
        let previous = latest
        previous?.cancel()
        run += 1
        let run = run
        isRunning = true
        latest = Task { [weak self] in
            // Auf das tatsächliche Ende warten: Das Warten auf `value` endet nicht mit dem eigenen Abbruch.
            await previous?.value
            guard !Task.isCancelled else { return }
            let value = await operation()
            guard !Task.isCancelled, let self, self.run == run else { return }
            self.isRunning = false
            onFinish(value)
        }
    }

    /// Bricht den laufenden Lauf ab; sein Ergebnis verfällt. Mehrfach aufrufbar.
    public func cancel() {
        latest?.cancel()
        isRunning = false
    }

    /// Wartet, bis der letzte Lauf samt aller vorigen zu Ende ist (für Tests).
    func settled() async {
        await latest?.value
    }
}
