import Darwin
import Foundation
import Observation

/// Zustand des Tabs „Dienste“: liest die Domänen `gui/<uid>` und `system` nebenläufig (`LaunchdServiceReader`, nur
/// lesend). Die Oberfläche ruft `refresh()` beim Erscheinen, alle `refreshInterval` und nach einer Aktion; ein älterer,
/// später fertiger Lauf wird verworfen. Eine nicht lesbare Domäne legt nur sich selbst lahm (Spec §5).
@MainActor
@Observable
public final class LaunchdServicesModel {
    public static let refreshInterval: Duration = .seconds(5)

    public private(set) var listings: [LaunchdServiceDomain: [LaunchdServiceStatus]] = [:]
    /// Meldungen nicht lesbarer Domänen („system: …“), in fester Reihenfolge.
    public private(set) var failures: [String] = []
    public private(set) var hasLoaded = false

    @ObservationIgnored private let reader: LaunchdServiceReader
    @ObservationIgnored private let domains: [LaunchdServiceDomain]
    @ObservationIgnored private var generation = RequestGeneration()

    public init(reader: LaunchdServiceReader = LaunchdServiceReader(), uid: uid_t = getuid()) {
        self.reader = reader
        domains = [.user(uid), .system]
    }

    /// Ergebnis einer Domäne aus der Task-Gruppe.
    ///
    /// Bewusst ein Struct statt eines `(Domäne, Result)`-Tupels: Unter `-O` kam ein solches Tupel aus der Task-Gruppe
    /// falsch an, die Liste der Benutzerdomäne fehlte dann im Release-Build (wie beim Scan, `ScanCoordinator.IndexedOutcome`).
    private struct DomainResult: Sendable {
        let domain: LaunchdServiceDomain
        let result: Result<[LaunchdServiceStatus], any Error>
    }

    public func refresh() async {
        let request = generation.begin()
        let reader = reader
        var results: [LaunchdServiceDomain: Result<[LaunchdServiceStatus], any Error>] = [:]
        await withTaskGroup(of: DomainResult.self) { group in
            for domain in domains {
                group.addTask {
                    do {
                        return DomainResult(domain: domain, result: .success(try await reader.services(in: domain)))
                    } catch {
                        return DomainResult(domain: domain, result: .failure(error))
                    }
                }
            }
            for await item in group { results[item.domain] = item.result }
        }
        guard !Task.isCancelled, generation.isCurrent(request) else { return }
        listings = results.compactMapValues { try? $0.get() }
        failures = domains.compactMap { domain in
            guard case .failure(let error)? = results[domain] else { return nil }
            return "\(domain.name): \(error.readableDescription)"
        }
        hasLoaded = true
    }
}
