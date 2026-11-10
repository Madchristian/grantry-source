import Foundation
@testable import ManagerKit

/// Coordinator-Ersatz für Aktionen des Task-Managers („Task beenden“, Dienste): Sie brauchen nur, dass Aktionen
/// verfügbar sind; alles andere gelingt sofort.
final class IdlePerformer: ActionPerforming {
    func reset(_ grant: PermissionGrant) async -> ActionOutcome { .done }
    func resetService(_ reset: ServiceReset) async -> ActionOutcome { .done }
    func setEnabled(_ item: AutostartItem, _ enabled: Bool) async -> ActionOutcome { .done }
    func remove(_ item: AutostartItem) async -> ActionOutcome { .done }
    func restore(receiptID: UUID) async -> ActionOutcome { .done }
    func removeServer(_ entry: MCPServerEntry) async -> ActionOutcome { .done }
    func setServerEnabled(_ entry: MCPServerEntry, _ enabled: Bool) async -> ActionOutcome { .done }
    func restoreAgentChange(_ change: AgentConfigChange) async -> ActionOutcome { .done }
    func terminate(_ request: ProcessTerminationRequest, force: Bool) async -> ProcessTerminationResult {
        ProcessTerminationResult(request: request, force: force, outcome: .done, report: ProcessTerminationReport())
    }
    func perform(_ action: SecurityAction) async -> ActionOutcome { .done }
    func performRemoval(
        _ plan: RemovalPlan, onExecuted: @escaping @Sendable (RemovalReport) async -> Void
    ) async -> RemovalReport { RemovalReport(entries: []) }
    func drain() async {}
}
