import Testing
import TestSupport
import ManagerKit

@MainActor
@Suite struct HelperActivityLockTests {
    @Test func actionsAndHelperMaintenanceExcludeEachOther() {
        let lock = HelperActivityLock()
        #expect(lock.begin(.action))
        #expect(!lock.begin(.helperMaintenance))
        #expect(!lock.begin(.action))
        #expect(lock.current == .action)
        lock.end(.action)
        #expect(lock.current == nil)
        #expect(lock.begin(.helperMaintenance))
        #expect(!lock.begin(.action))
    }

    @Test func endingAnotherActivityKeepsTheLock() {
        let lock = HelperActivityLock()
        #expect(lock.begin(.helperMaintenance))
        lock.end(.action)
        #expect(lock.current == .helperMaintenance)
    }

    @Test(.timeLimit(.minutes(1))) func performSkipsWhileBusyAndReleasesAfterwards() async throws {
        let lock = HelperActivityLock()
        let gate = Gate()
        let running = Task { await lock.perform(.helperMaintenance) { try? await gate.wait(); return 1 } }
        while lock.current == nil { await Task.yield() }

        #expect(await lock.perform(.action) { 2 } == nil)
        gate.open()
        #expect(await running.value == 1)
        #expect(lock.current == nil)
        #expect(await lock.perform(.action) { 3 } == 3)
    }

    // MARK: - Neu installieren trotz laufender Aktion

    @Test func maintenanceIsFreeWhenIdle() {
        let lock = HelperActivityLock()
        #expect(lock.maintenanceAccess(helperState: .ready) == .free)
        #expect(lock.maintenanceAccess(helperState: .unreachable("Zeitüberschreitung nach 5 s")) == .free)
    }

    /// Ist der Helper nicht erreichbar, kommt eine laufende Aktion ohnehin nicht voran: Sie wird abgebrochen, statt die
    /// Reparatur zu sperren.
    @Test func unreachableHelperMayBeRepairedAfterAbandoningTheAction() {
        let lock = HelperActivityLock()
        #expect(lock.begin(.action))
        #expect(lock.maintenanceAccess(helperState: .unreachable("Zeitüberschreitung nach 5 s")) == .afterAbandoningAction)
    }

    @Test(arguments: [HelperState.ready, .outdated(installed: 1, expected: 2), .notInstalled, .awaitingApproval] as [HelperState?]
        + [nil])
    func otherwiseARunningActionBlocksMaintenance(state: HelperState?) {
        let lock = HelperActivityLock()
        #expect(lock.begin(.action))
        #expect(lock.maintenanceAccess(helperState: state) == .blocked)
    }

    @Test func runningMaintenanceBlocksFurtherMaintenance() {
        let lock = HelperActivityLock()
        #expect(lock.begin(.helperMaintenance))
        #expect(lock.maintenanceAccess(helperState: .unreachable("x")) == .blocked)
    }
}
