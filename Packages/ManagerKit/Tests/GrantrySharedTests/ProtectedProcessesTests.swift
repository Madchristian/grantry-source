import Darwin
import Foundation
import Testing
import TestSupport
@testable import GrantryShared

@Suite struct ProtectedProcessesTests {
    private static let windowServer =
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
    private static let loginwindow = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"

    @Test func protectsKernelLaunchdAndListedPrograms() {
        let list = ProtectedProcesses.system
        #expect(list.protects(pid: 0, executablePath: ""))
        #expect(list.protects(pid: 1, executablePath: "/sbin/launchd"))
        #expect(list.protects(pid: 606, executablePath: Self.windowServer))
        #expect(list.protects(pid: 620, executablePath: Self.loginwindow))
        #expect(!list.protects(pid: 4242, executablePath: "/usr/local/sbin/listener"))
        #expect(!list.protects(pid: 4242, executablePath: ""))
    }

    /// Über Symlinks erreichte Pfade zählen gleich (`…/Resources` ist ein Link auf `Versions/A/Resources`).
    @Test func comparesCanonicalPaths() {
        #expect(ProtectedProcesses.system.protects(
            pid: 606, executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        ))
    }

    /// Ein gleichnamiges Programm an anderem Ort ist ein anderes Programm.
    @Test func nameAloneIsNotProtected() {
        #expect(!ProtectedProcesses.system.protects(pid: 4242, executablePath: "/tmp/loginwindow"))
    }

    /// Laufende `WindowServer`/`loginwindow` (mit Anmeldung am Mac) erkennt die Liste über ihren Kernel-Pfad (nur lesend).
    @Test func recognisesRunningSystemProcesses() {
        let paths = Self.runningPIDs().compactMap(LibprocProcessInspector.executablePath(of:))
        for path in paths where ["WindowServer", "loginwindow"].contains((path as NSString).lastPathComponent) {
            #expect(ProtectedProcesses.system.protects(pid: 2, executablePath: path), "\(path)")
        }
    }

    @Test func everyEntryHasNameAndReason() {
        for entry in ProtectedProcesses.system.entries {
            #expect(!entry.name.isEmpty && !entry.reason.isEmpty && entry.path.hasPrefix("/"), "\(entry)")
        }
    }

    // MARK: - Policies des Task-Managers

    private static let own = RunningProcess(pid: 620, uid: 501, executablePath: loginwindow, startTime: 1)
    private static let foreign = RunningProcess(pid: 4242, uid: 0, executablePath: "/usr/local/sbin/agent", startTime: 1)

    /// `loginwindow` läuft unter der eigenen UID; die App beendet es trotzdem nie.
    @Test func appPolicyRejectsProtectedOwnProcess() {
        let policy = ProcessTerminationPolicy.taskManagerProcess(
            bundlePath: "/Applications/Grantry.app", inspector: FixedProcessInspector([Self.own])
        )
        #expect(throws: ProcessTerminationViolation.systemCritical("loginwindow")) {
            try policy.validate(pid: 620, executablePath: Self.loginwindow, requiredUID: 501, startTime: 1)
        }
    }

    @Test func helperPolicyAcceptsForeignProcessWithoutListeningOrSignatureCheck() throws {
        let policy = ProcessTerminationPolicy.taskManagerHelper(
            executablePath: "/Applications/Grantry.app/Contents/MacOS/GrantryHelper",
            inspector: FixedProcessInspector([Self.foreign])
        )
        let target = try policy.validate(pid: 4242, executablePath: "/usr/local/sbin/agent", excludingUID: 501,
                                         startTime: 1, callerPID: 777)
        #expect(target == .running(Self.foreign))
    }

    @Test func helperPolicyRejectsCallersOwnProcess() {
        let policy = ProcessTerminationPolicy.taskManagerHelper(
            executablePath: "/Applications/Grantry.app/Contents/MacOS/GrantryHelper",
            inspector: FixedProcessInspector([Self.foreign])
        )
        #expect(throws: ProcessTerminationViolation.ownProcess(4242)) {
            try policy.validate(pid: 4242, executablePath: "/usr/local/sbin/agent", excludingUID: 0, startTime: 1,
                                callerPID: 777)
        }
    }

    @Test func helperPolicyWithoutBundleRejectsEverything() {
        let policy = ProcessTerminationPolicy.taskManagerHelper(executablePath: "/usr/local/bin/helper",
                                                                inspector: FixedProcessInspector([Self.foreign]))
        #expect(throws: ProcessTerminationViolation.ownBundleUnknown) {
            try policy.validate(pid: 4242, executablePath: "/usr/local/sbin/agent", startTime: 1, callerPID: 777)
        }
    }

    @Test func systemCriticalMessageNamesProgram() {
        #expect(ProcessTerminationViolation.systemCritical("WindowServer").errorDescription
            == "„WindowServer“ ist für macOS unverzichtbar – Grantry beendet den Prozess nicht und ändert seine Priorität nicht")
    }

    private static func runningPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(bytes))))
    }
}
