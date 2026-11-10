import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Datenträger-Befunde im vorhandenen Scan (TM-15.5): kein eigener Takt, höchstens eine Lesung je
/// `minimumInterval`, nie zwei gleichzeitig.
@MainActor
@Suite struct VolumeFindingCheckTests {
    private typealias F = FindingFixtures

    private final class Fake: Sendable {
        let reads = Mutex(0)
        let time = Mutex(F.start)
        let gate: Gate?

        init(gate: Gate? = nil) { self.gate = gate }

        func read() async -> VolumeInventory {
            reads.withLock { $0 += 1 }
            try? await gate?.wait()
            return VolumeInventory(devices: [StorageDevice(id: "disk0", smartStatus: .failing)], localSnapshots: nil,
                                   isComplete: true)
        }

        func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private func check(_ fake: Fake, received: @escaping @MainActor (VolumeInventory, Date) -> Void = { _, _ in })
        -> VolumeFindingCheck {
        let check = VolumeFindingCheck(read: { await fake.read() }, now: { fake.time.withLock { $0 } })
        check.onInventory = received
        return check
    }

    @Test func firstScanReadsTheInventory() async {
        let fake = Fake()
        var received: [Date] = []
        let check = check(fake) { inventory, time in
            #expect(inventory.devices.first?.smartStatus == .failing)
            received.append(time)
        }
        await check.scanFinished()?.value
        #expect(fake.reads.withLock { $0 } == 1)
        #expect(received == [F.start])
    }

    /// Scans kommen auch bei jeder Dateiänderung; das Inventar wird höchstens alle `minimumInterval` gelesen.
    @Test func laterScansReadOnlyAfterTheInterval() async {
        let fake = Fake()
        let check = check(fake)
        await check.scanFinished()?.value
        fake.advance(VolumeFindingCheck.minimumInterval - 1)
        #expect(check.scanFinished() == nil)
        fake.advance(1)
        await check.scanFinished()?.value
        #expect(fake.reads.withLock { $0 } == 2)
    }

    /// Läuft eine Lesung noch, startet ein weiterer Scan keine zweite.
    @Test func noOverlappingReads() async {
        let gate = Gate()
        let fake = Fake(gate: gate)
        let check = check(fake)
        let running = check.scanFinished()
        fake.advance(VolumeFindingCheck.minimumInterval * 2)
        #expect(check.scanFinished() == nil)
        gate.open()
        await running?.value
        #expect(fake.reads.withLock { $0 } == 1)
    }

    /// `cancel()` beim Beenden: Ein spätes Ergebnis kommt nicht mehr an.
    @Test func cancelDropsALateResult() async {
        let gate = Gate()
        let fake = Fake(gate: gate)
        var received = 0
        let check = check(fake) { _, _ in received += 1 }
        let running = check.scanFinished()
        check.cancel()
        gate.open()
        await running?.value
        #expect(received == 0)
    }
}
