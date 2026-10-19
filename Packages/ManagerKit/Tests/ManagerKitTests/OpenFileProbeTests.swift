import Darwin
import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct OpenFileProbeTests {
    private let derivedData = ProcessLock(processes: ["xcodebuild", "SWBBuildService"], ownedEntryPattern: ".+-[a-z]{28}")
    private let project = "/Users/a/DerivedData/App-abcdefghijklmnopqrstuvwxyzab"

    @Test func openFileLocksThePathAndEverythingAboveIt() {
        let usage = ProcessUsage(running: ["xcodebuild"],
                                 openPaths: [OpenPath(processName: "xcodebuild", path: project + "/Build/x.o")])
        #expect(usage.lockReason(for: project, lock: derivedData) == "Wird gerade benutzt von xcodebuild")
        #expect(usage.lockReason(for: project.uppercased(), lock: derivedData) == "Wird gerade benutzt von xcodebuild")
        #expect(usage.lockReason(for: project + "/Build/x.o", lock: derivedData) == "Wird gerade benutzt von xcodebuild")
        // Nur ganze Pfadteile: `…ab` sperrt nicht `…a` (ohne laufenden Build, sonst gälte der kürzere Name als geteilt).
        let openOnly = ProcessUsage(running: [], openPaths: usage.openPaths)
        #expect(openOnly.lockReason(for: String(project.dropLast()), lock: derivedData) == nil)
        #expect(usage.lockReason(for: "/Users/a/DerivedData/Other-zyxwvutsrqponmlkjihgfedcbazy", lock: derivedData) == nil)
    }

    /// Claude-Review #226: Compiler blenden geteilte Caches nur ein – sie sperrt schon ein laufender Build.
    @Test func sharedCachesAreLockedWhileABuildRuns() {
        let idle = ProcessUsage(running: [], openPaths: [])
        let building = ProcessUsage(running: ["SWBBuildService"], openPaths: [])
        for cache in ["ModuleCache.noindex", "SDKExplicitPrecompiledModules", "SDKStatCaches.noindex"] {
            #expect(idle.lockReason(for: "/d/" + cache, lock: derivedData) == nil)
            #expect(building.lockReason(for: "/d/" + cache, lock: derivedData) == "Geteilter Cache, SWBBuildService läuft")
        }
        #expect(building.lockReason(for: project, lock: derivedData) == nil)
        #expect(building.lockReason(for: "/d/ModuleCache.noindex", lock: ProcessLock(processes: ["SWBBuildService"])) == nil)
        #expect(ProcessLock(processes: [], ownedEntryPattern: "(").isShared("App-abc"))
    }

    @Test func verdictBlocksLockedPathsAndFailsClosed() {
        let lock = ProcessLock(processes: ["SWBBuildService"])
        let used = FakeOpenFileProbe([OpenPath(processName: "SWBBuildService", path: "/d/App/build.db")])
        #expect(used.verdict(for: "/d/App", lock: lock) == .blocked("Wird gerade benutzt von SWBBuildService"))
        #expect(used.verdict(for: "/d/Other", lock: lock) == .allowed)
        #expect(FakeOpenFileProbe(nil).verdict(for: "/d/App", lock: lock)
                == .blocked("Nicht prüfbar, ob ein Prozess den Ordner benutzt"))
        let unused = FakeOpenFileProbe(nil)
        #expect(unused.verdict(for: "/d/App", lock: nil) == .allowed)
        #expect(unused.usage(for: nil) == nil)
        #expect(unused.callCount == 0)
    }

    /// Echte Prozessliste: Der eigene Testprozess hält eine Datei offen und wird über seinen `p_comm` gefunden.
    @Test func libprocProbeFindsOwnOpenFile() throws {
        let own = try #require(try LibprocProcessTable.kernelEntries().first { $0.kp_proc.p_pid == getpid() })
        let name = try #require(LibprocProcessTable.string(from: own.kp_proc.p_comm))
        try ScratchDirectory.withCanonical(prefix: "open-file-probe") { scratch in
            let file = scratch.appending(path: "held.txt")
            try Data("x".utf8).write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let usage = try LibprocOpenFileProbe().usage(ofProcessesNamed: [name])
            #expect(usage.running == [name])
            #expect(usage.lockReason(for: scratch.path, lock: ProcessLock(processes: [name])) == "Wird gerade benutzt von \(name)")
            let none = try LibprocOpenFileProbe().usage(ofProcessesNamed: ["no-such-process-\(getpid())"])
            #expect(none.running.isEmpty && none.openPaths.isEmpty)
        }
    }
}
