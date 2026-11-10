import Foundation
import GrantryShared
import Observation
import os

/// Zweite Quelle des Tabs „Prozesse“ für Prozesse anderer Benutzer (Muster `NetworkActivityModel`): `/bin/ps` als
/// Unterprozess alle `interval`, nur zwischen `start()` und `stop()` – die Oberfläche koppelt beides an die
/// Sichtbarkeit des Tabs. Ein Lauf kostet rund 20 ms. Scheitert `ps`, bleibt `usage` leer (die Oberfläche zeigt „–“);
/// gemeldet wird das einmal je Lebensdauer.
@MainActor
@Observable
public final class ForeignProcessUsageModel {
    public nonisolated static let executable = "/bin/ps"
    public static let interval: Duration = .seconds(2)
    nonisolated static let timeout: Duration = .seconds(5)
    private nonisolated static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "task-manager")

    /// Letzter Stand je PID; leer, solange nicht gemessen wird.
    public private(set) var usage: [Int32: ForeignProcessUsage] = [:]

    @ObservationIgnored private let runner: any CommandRunning
    @ObservationIgnored private let coreCount: Int
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var reportedFailure = false

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        coreCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.runner = runner
        self.coreCount = coreCount
        self.sleep = sleep
    }

    isolated deinit {
        task?.cancel()
    }

    public var isRunning: Bool { task != nil }

    /// Tabs, die die Werte zeigen. Beim Wechsel zwischen „Prozesse“ und „Details“ erscheint der neue Tab, bevor der alte
    /// verschwindet; gezählte Abnehmer verhindern, dass dessen `stop` die Messung des neuen beendet.
    public enum Consumer: Hashable, Sendable {
        case processesTab, detailsTab, usersTab, overviewTab
    }

    @ObservationIgnored private var consumers: Set<Consumer> = []

    /// Misst, solange mindestens ein Abnehmer da ist.
    public func start(for consumer: Consumer) {
        consumers.insert(consumer)
        start()
    }

    public func stop(for consumer: Consumer) {
        consumers.remove(consumer)
        if consumers.isEmpty { stop() }
    }

    /// Misst sofort und dann alle `interval`, bis `stop()`.
    public func start() {
        guard task == nil else { return }
        let runner = runner, coreCount = coreCount, sleep = sleep
        task = Task { [weak self] in
            while !Task.isCancelled {
                let result = await Self.read(runner: runner, coreCount: coreCount)
                guard !Task.isCancelled else { return }
                self?.apply(result)
                do { try await sleep(Self.interval) } catch { return }
            }
        }
    }

    /// Hört auf; ein laufendes `ps` endet von selbst (Frist `timeout`).
    public func stop() {
        task?.cancel()
        task = nil
        usage = [:]
    }

    /// `LC_ALL=C` für einen festen Dezimalpunkt; die Umgebung ersetzt die geerbte vollständig.
    nonisolated static func read(runner: any CommandRunning,
                                 coreCount: Int) async -> Result<[Int32: ForeignProcessUsage], any Error> {
        do {
            let result = try await runner.run(executable, PSUsageParser.arguments, timeout: timeout,
                                              environment: ["LC_ALL": "C"])
            guard result.succeeded else {
                throw CommandError.launchFailed(executable: executable, reason: "Exit-Code \(result.exitCode)")
            }
            return .success(PSUsageParser.parse(result.stdout, coreCount: coreCount))
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ result: Result<[Int32: ForeignProcessUsage], any Error>) {
        switch result {
        case .success(let usage):
            self.usage = usage
        case .failure(let error):
            usage = [:]
            guard !reportedFailure else { return }
            reportedFailure = true
            Self.logger.error("ps nicht lesbar: \(error.readableDescription, privacy: .public)")
        }
    }
}
