import Foundation
import Testing
@testable import ManagerKit

/// Opt-in gegen das echte System (`MANAGERKIT_LIVE=1`), nie in der CI: Die Kategorien aus #226 lesen nur – `simctl
/// runtime list`, Websitedaten und offene Dateien von Builds – und melden ihren Fund auf der Konsole.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"))
struct StorageLiveTests {
    private func print(_ report: StorageCategoryReport) {
        Swift.print("[\(report.category.id)] \(report.status) \(report.sizeText), \(report.items.count) Einträge")
        for item in report.items.prefix(10) {
            Swift.print("  \(item.title) – \(item.sizeText) – \(item.detail ?? "") – wählbar: \(item.isSelectable)")
        }
    }

    @Test func simulatorRuntimesParseTheRealListing() async {
        let home = NSHomeDirectory()
        let report = await SimulatorRuntimesProvider(requiredPath: home + "/Library/Developer/CoreSimulator/Devices",
                                                     runner: ProcessCommandRunner(), locator: ToolLocator(home: home)).scan()
        print(report)
        #expect(report.status == .available || report.status == .notInstalled)
    }

    @Test func webKitWALScanFinishesOnTheRealHome() async {
        let start = ContinuousClock.now
        let report = await WebKitWALProvider(home: NSHomeDirectory(),
                                             canReadAppContainers: { await FullDiskAccessProbe().hasFullDiskAccess() }).scan()
        print(report)
        Swift.print("  Dauer: \(ContinuousClock.now - start)")
        #expect(report.category.risk == .reportOnly)
    }

    /// #229: liest nur. Ein gerade benutzter Arbeitsordner (etwa der des aufrufenden Agenten) ist nie vorausgewählt.
    @Test func agentWorkdirsScanTheRealFolders() async {
        let home = NSHomeDirectory()
        let start = ContinuousClock.now
        let report = await AgentWorkdirsProvider(claudeRoot: "/private/tmp/claude-\(getuid())", codexRoot: home + "/.codex/.tmp",
                                                 home: home, minimumAgeDays: StorageCatalog.agentWorkdirMinimumAgeDays,
                                                 measurer: FileSizeCalculator()).scan()
        print(report)
        Swift.print("  Dauer: \(ContinuousClock.now - start), vorausgewählt: \(report.items.filter(\.isPreselected).count)")
        let busy = report.items.filter { $0.detail?.hasPrefix("Wird gerade benutzt") == true }
        #expect(busy.allSatisfy { !$0.isPreselected })
    }

    @Test func openFilesOfRunningBuilds() throws {
        let usage = try LibprocOpenFileProbe().usage(ofProcessesNamed: StorageCatalog.buildLock.processes)
        Swift.print("[openFiles] laufend: \(usage.running.sorted()), \(usage.openPaths.count) Pfade")
        for path in usage.openPaths.map(\.path).filter({ $0.contains("DerivedData") }).prefix(5) { Swift.print("  \(path)") }
    }
}
