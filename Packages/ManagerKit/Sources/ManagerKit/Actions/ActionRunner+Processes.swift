import Foundation

/// „Prozess beenden …“ (#128) – Ergebnis im Kontext `.network`.
extension ActionRunner {
    /// Beendet die Prozesse (nach Bestätigung); `runningRecordID` ist die ID des Lauschers. `nil`, wenn die Aktion nicht
    /// begonnen hat (es lief schon eine Aktion oder eine Helper-Installation) oder abgebrochen wurde.
    @discardableResult
    public func terminate(
        _ request: ProcessTerminationRequest, force: Bool, context: ActionContext = .network
    ) async -> ProcessTerminationResult? {
        var finished: ProcessTerminationResult?
        await run(recordID: request.id, context: context, unavailable: { ProcessTerminationResult.unavailable(request, force: force) }) {
            coordinator in
            await coordinator.terminate(request, force: force)
        } present: { result in
            finished = result
            return .termination(result)
        }
        return finished
    }
}
