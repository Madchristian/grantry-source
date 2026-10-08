import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

// Nur Attrappen: Kein Test meldet echte Dienste ab oder legt etwas in den Papierkorb.

@MainActor
@Suite("Ablauf „Grantry deinstallieren …“")
struct SelfUninstallFlowTests {
    private let app = LeftoverCandidate(path: "/Applications/Grantry.app", kind: .appBundle, confidence: .safe)
    private let preferences = LeftoverCandidate(
        path: "/Users/test/Library/Preferences/de.cstrube.Grantry.plist", kind: .preferences, confidence: .safe
    )
    private let plan = SelfUninstallPlan(files: [], grants: [])

    private func report(_ entries: [SelfUninstallReport.Entry]) -> SelfUninstallReport {
        SelfUninstallReport(entries: entries, automationDenied: false)
    }

    /// Das reguläre Beenden wartet den laufenden Ablauf ab (#156): `drain()` kehrt erst mit dem Bericht zurück.
    @Test(.timeLimit(.minutes(1))) func drainWaitsForTheRunningUninstall() async throws {
        let gate = Gate()
        let lock = HelperActivityLock()
        let flow = SelfUninstallFlow(helperActivity: lock) { _, _ in
            try? await gate.wait()
            return SelfUninstallReport(entries: [], automationDenied: false)
        }
        let running = Task { await flow.run(plan) }
        // `isRunning` gilt, sobald die Aufgabe angelegt ist – die Sperre nimmt sie erst, wenn sie anläuft.
        while !flow.isRunning || lock.current == nil { await Task.yield() }
        #expect(lock.current == .helperMaintenance)

        let drained = Mutex(false)
        let draining = Task {
            await flow.drain()
            drained.withLock { $0 = true }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!drained.withLock { $0 })

        gate.open()
        #expect(await running.value != nil)
        await draining.value
        #expect(drained.withLock { $0 })
        #expect(!flow.isRunning)
        #expect(lock.current == nil)
    }

    @Test func drainWithoutRunningUninstallReturnsAtOnce() async {
        let flow = SelfUninstallFlow(helperActivity: HelperActivityLock()) { _, _ in
            Issue.record("nicht erwartet")
            return SelfUninstallReport(entries: [], automationDenied: false)
        }
        await flow.drain()
        #expect(!flow.isRunning)
    }

    /// Läuft schon eine Aktion, eine Helper-Wartung oder ein Ablauf, beginnt kein zweiter.
    @Test(.timeLimit(.minutes(1))) func runIsRefusedWhileSomethingElseRuns() async throws {
        let gate = Gate()
        let lock = HelperActivityLock()
        let started = Mutex(0)
        let flow = SelfUninstallFlow(helperActivity: lock) { _, _ in
            started.withLock { $0 += 1 }
            try? await gate.wait()
            return SelfUninstallReport(entries: [], automationDenied: false)
        }
        #expect(lock.begin(.action))
        #expect(await flow.run(plan) == nil)
        lock.end(.action)

        let first = Task { await flow.run(plan) }
        while !flow.isRunning { await Task.yield() }
        #expect(await flow.run(plan) == nil)
        gate.open()
        #expect(await first.value != nil)
        #expect(started.withLock { $0 } == 1)
    }

    /// Die Einstellungen werden nur geleert, wenn Grantry im Papierkorb liegt **und** ihre Datei mit ausgewählt war.
    @Test func clearsPreferencesOnlyAfterRemovingAppAndPreferences() async {
        let outcomes = Mutex<[SelfUninstallReport]>([
            report([.init(subject: .file(app), result: .done)]),
            report([.init(subject: .file(app), result: .done), .init(subject: .file(preferences), result: .done)]),
            report([.init(subject: .file(app), result: .failed("Abgebrochen")), .init(subject: .file(preferences), result: .done)]),
        ])
        let flow = SelfUninstallFlow(
            helperActivity: HelperActivityLock(), uninstall: { _, _ in outcomes.withLock { $0.removeFirst() } },
            isInTrash: { _ in true }
        )
        #expect(!flow.clearsPreferences)
        _ = await flow.run(plan)
        #expect(!flow.clearsPreferences)
        _ = await flow.run(plan)
        #expect(flow.clearsPreferences)
        _ = await flow.run(plan)
        #expect(!flow.clearsPreferences)
    }

    /// Festgehaltene Originale leben über Wiederholungen bis zum Beenden; frei werden sie erst bei einem neuen Ablauf
    /// oder beim Schließen des Berichts (#143).
    @Test func trackingIsReleasedOnNewRunAndDismissOnly() async {
        let releases = Mutex(0)
        let cancelled = report([.init(subject: .file(app), result: .failed("Abgebrochen"))])
        let flow = SelfUninstallFlow(
            helperActivity: HelperActivityLock(),
            uninstall: { _, _ in cancelled },
            isInTrash: { _ in true }, releaseTracking: { releases.withLock { $0 += 1 } }
        )
        _ = await flow.run(plan)
        #expect(releases.withLock { $0 } == 1)
        _ = await flow.retry()
        #expect(releases.withLock { $0 } == 1, "eine Wiederholung braucht die Deskriptoren noch")
        flow.dismiss()
        #expect(releases.withLock { $0 } == 2)
    }

    /// Unmittelbar vor dem Leeren beim Beenden wird erneut geprüft, dass die Sicherung der Einstellungen im Papierkorb
    /// liegt; wurde sie zurückgelegt oder entfernt, bleiben die Einstellungen (#143).
    @Test func preferencesStayWhenTheirBackupLeftTheTrash() async {
        let inTrash = Mutex(true)
        let flow = SelfUninstallFlow(
            helperActivity: HelperActivityLock(),
            uninstall: { _, _ in
                SelfUninstallReport(entries: [
                    .init(subject: .file(app), result: .done), .init(subject: .file(preferences), result: .done),
                ], automationDenied: false)
            },
            isInTrash: { file in file == preferences && inTrash.withLock { $0 } }
        )
        _ = await flow.run(plan)
        #expect(flow.clearsPreferences)
        inTrash.withLock { $0 = false }
        #expect(!flow.clearsPreferences)
    }
}
