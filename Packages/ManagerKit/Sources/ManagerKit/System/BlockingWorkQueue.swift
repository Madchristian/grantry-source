import Foundation

/// Serielle Brücke für synchrone Systemarbeit: Nur die eigene Queue wartet blockierend, der Swift-Task suspendiert.
/// Ein Abbruch beendet das Warten bewusst nicht vor der Arbeit. So bleibt insbesondere `RunningSources` des
/// ScanCoordinators bis zum tatsächlichen Ende belegt; wiederholte Scans nach Frist/Abbruch stauen keine Arbeit auf.
/// Aufrufer reichen Arbeit nacheinander ein, statt für jeden Pfad einen unabhängigen Task zu starten.
final class BlockingWorkQueue: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: "\(ManagerKit.logSubsystem).\(label)", qos: .utility)
    }

    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    func runThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run { Result(catching: body) }.get()
    }
}
