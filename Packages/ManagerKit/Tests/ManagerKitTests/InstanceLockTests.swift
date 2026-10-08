import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// `flock` gilt je geöffneter Datei – zwei `acquire` im selben Prozess schließen einander daher aus wie zwei Prozesse.
///
/// Die Sperre öffnet ihren Pfad ohne Symlink-Auflösung; die Tests arbeiten daher in symlinkfreien Scratch-Pfaden.
@Suite struct InstanceLockTests {
    private static let foreignContents = Data("fremder Inhalt\n".utf8)

    private func withLockURL(_ body: (URL) throws -> Void) throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            try body(directory.appending(path: "nested/Instance.lock"))
        }
    }

    @Test func acquiresAFreeLockAndCreatesItsDirectory() throws {
        try withLockURL { url in
            guard case .acquired = try InstanceLock.acquire(at: url) else {
                Issue.record("Sperre nicht erhalten")
                return
            }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func secondAcquireSeesARunningHolder() throws {
        try withLockURL { url in
            let first = try InstanceLock.acquire(at: url)
            #expect(try InstanceLock.acquire(at: url) == .held(byTerminatingInstance: false))
            withExtendedLifetime(first) {}
        }
    }

    @Test func holderMarkedAsTerminatingIsReported() throws {
        try withLockURL { url in
            guard case .acquired(let lock) = try InstanceLock.acquire(at: url) else {
                Issue.record("Sperre nicht erhalten")
                return
            }
            try lock.markTerminating()
            #expect(try InstanceLock.acquire(at: url) == .held(byTerminatingInstance: true))
        }
    }

    @Test func releasedLockCanBeAcquiredAgain() throws {
        try withLockURL { url in
            var first: InstanceLock.Acquisition? = try InstanceLock.acquire(at: url)
            if case .acquired(let lock) = first { try lock.markTerminating() }
            first = nil
            guard case .acquired = try InstanceLock.acquire(at: url) else {
                Issue.record("Freigegebene Sperre nicht erhalten")
                return
            }
            withExtendedLifetime(first) {}
        }
    }

    @Test func waitingAcquireGivesUpAfterTheTimeout() throws {
        try withLockURL { url in
            let holder = try InstanceLock.acquire(at: url)
            #expect(try InstanceLock.acquire(at: url, waitingUpTo: .milliseconds(200)) == nil)
            withExtendedLifetime(holder) {}
        }
    }

    @Test func waitingAcquireSucceedsOnceTheHolderReleases() async throws {
        try await ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let url = directory.appending(path: "Instance.lock")
            // Der Halter läuft auf einem eigenen Thread: Das wartende `acquire` blockiert seinen Thread, und läge der
            // Halter im kooperativen Pool, könnte er bei wenigen Kernen seine Sperre nicht rechtzeitig freigeben.
            let holderLocked = Mutex(false)
            let acquired = Gate()
            Thread.detachNewThread {
                let lock = try? InstanceLock.acquire(at: url)
                holderLocked.withLock { $0 = lock != nil }
                acquired.open()
                Thread.sleep(forTimeInterval: 0.2)
                withExtendedLifetime(lock) {}
            }
            try await acquired.wait()
            #expect(holderLocked.withLock { $0 })
            let waited = Task.detached { try InstanceLock.acquire(at: url, waitingUpTo: .seconds(10)) }
            #expect(try await waited.value != nil)
        }
    }

    // MARK: - Manipulierte Sperrdatei und Ordnerkette (#136)

    /// Fremde Datei mit bekanntem Inhalt in `directory`.
    private func makeForeignFile(in directory: URL) throws -> URL {
        let target = directory.appending(path: "fremd.txt")
        try Self.foreignContents.write(to: target)
        return target
    }

    @Test func refusesASymlinkedLockFileAndLeavesItsTargetUnchanged() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let target = try makeForeignFile(in: directory)
            let url = directory.appending(path: "Instance.lock")
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            #expect(throws: POSIXError(.ELOOP)) { try InstanceLock.acquire(at: url) }
            #expect(try Data(contentsOf: target) == Self.foreignContents)
        }
    }

    @Test func refusesADanglingSymlinkWithoutCreatingItsTarget() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let target = directory.appending(path: "fehlt.txt")
            let url = directory.appending(path: "Instance.lock")
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            #expect(throws: POSIXError(.ELOOP)) { try InstanceLock.acquire(at: url) }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func refusesASymlinkedParentDirectory() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let real = directory.appending(path: "echt")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            let existing = real.appending(path: "Instance.lock")
            try Self.foreignContents.write(to: existing)
            let link = directory.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            #expect(throws: POSIXError(.ELOOP)) { try InstanceLock.acquire(at: link.appending(path: "Instance.lock")) }
            #expect(throws: POSIXError(.ELOOP)) { try InstanceLock.acquire(at: link.appending(path: "neu/Instance.lock")) }
            #expect(try Data(contentsOf: existing) == Self.foreignContents)
            #expect(!FileManager.default.fileExists(atPath: real.appending(path: "neu").path))
        }
    }

    @Test func refusesAHardLinkedLockFileAndLeavesTheOtherNameUnchanged() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let target = try makeForeignFile(in: directory)
            let url = directory.appending(path: "Instance.lock")
            try FileManager.default.linkItem(at: target, to: url)
            #expect(throws: InstanceLock.Refusal.multipleLinks) { try InstanceLock.acquire(at: url) }
            #expect(try Data(contentsOf: target) == Self.foreignContents)
        }
    }

    @Test func refusesALockFileThatIsNoRegularFile() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let url = directory.appending(path: "Instance.lock")
            try #require(mkfifo(url.path, 0o600) == 0)
            #expect(throws: InstanceLock.Refusal.notRegularFile) { try InstanceLock.acquire(at: url) }
        }
    }

    @Test func refusesADirectoryWritableByOthersWithoutStickyBit() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let shared = directory.appending(path: "offen")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try #require(chmod(shared.path, 0o777) == 0)
            #expect(throws: InstanceLock.Refusal.untrustedDirectory(path: shared.path)) {
                try InstanceLock.acquire(at: shared.appending(path: "Instance.lock"))
            }
            #expect(!FileManager.default.fileExists(atPath: shared.appending(path: "Instance.lock").path))
        }
    }

    @Test func acceptsADirectoryWritableByOthersWithStickyBit() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let shared = directory.appending(path: "sticky")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try #require(chmod(shared.path, 0o1777) == 0)
            guard case .acquired = try InstanceLock.acquire(at: shared.appending(path: "Instance.lock")) else {
                Issue.record("Sperre im Sticky-Ordner nicht erhalten")
                return
            }
        }
    }

    @Test func createdDirectoriesAndLockFileAreOwnerOnly() throws {
        try withLockURL { url in
            let lock = try InstanceLock.acquire(at: url)
            for (path, type) in [(url.deletingLastPathComponent().path, S_IFDIR), (url.path, S_IFREG)] {
                var info = stat()
                try #require(lstat(path, &info) == 0)
                #expect(info.st_mode & S_IFMT == type && info.st_mode & 0o077 == 0, "\(path)")
            }
            withExtendedLifetime(lock) {}
        }
    }

    @Test func lockFileHoldsTheMarkerAndPid() throws {
        try withLockURL { url in
            guard case .acquired(let lock) = try InstanceLock.acquire(at: url) else {
                Issue.record("Sperre nicht erhalten")
                return
            }
            let running = try #require(InstanceLockMarker(parsing: try String(contentsOf: url, encoding: .utf8)))
            #expect(running == InstanceLockMarker.current(.running))
            #expect(running.pid == getpid() && (running.startTime ?? 0) != 0)
            try lock.markTerminating()
            #expect(try String(contentsOf: url, encoding: .utf8) == InstanceLockMarker.current(.terminating).text)
        }
    }

    // MARK: - ACLs (#136)

    @Test func refusesADirectoryWhoseACLLetsOthersModifyIt() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let shared = directory.appending(path: "acl")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try #require(chmod(shared.path, 0o700) == 0)
            try AccessControlFixture.grant("group:staff allow delete_child,add_file", to: shared.path)
            #expect(throws: InstanceLock.Refusal.untrustedDirectory(path: shared.path)) {
                try InstanceLock.acquire(at: shared.appending(path: "Instance.lock"))
            }
            #expect(!FileManager.default.fileExists(atPath: shared.appending(path: "Instance.lock").path))
        }
    }

    @Test func refusesALockFileWhoseACLLetsOthersModifyIt() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let url = directory.appending(path: "Instance.lock")
            try Self.foreignContents.write(to: url)
            try #require(chmod(url.path, 0o600) == 0)
            try AccessControlFixture.grant("group:staff allow write,delete", to: url.path)
            #expect(throws: InstanceLock.Refusal.modifiableByOthers) { try InstanceLock.acquire(at: url) }
            #expect(try Data(contentsOf: url) == Self.foreignContents)
        }
    }

    @Test func acceptsDenyEntriesAndGrantsToTheOwnUser() throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let own = directory.appending(path: "eigen")
            try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
            try AccessControlFixture.grant("group:everyone deny delete", to: own.path)
            try AccessControlFixture.grant("user:\(NSUserName()) allow delete_child,add_file", to: own.path)
            guard case .acquired = try InstanceLock.acquire(at: own.appending(path: "Instance.lock")) else {
                Issue.record("Sperre trotz unbedenklicher ACL nicht erhalten")
                return
            }
        }
    }

    /// Nur lesend: Die Ordnerkette des echten Standard-Ablageorts (bis `Application Support`) muss akzeptiert werden –
    /// samt der üblichen ACLs wie `group:everyone deny delete` an Benutzer- und Library-Ordner.
    @Test func acceptsTheRealApplicationSupportChain() throws {
        let applicationSupport = StorageLocation.standard.directory.deletingLastPathComponent().path(percentEncoded: false)
        _ = try InstanceLock.trustedDirectory(at: applicationSupport)
    }

    // MARK: - Fehler beim Schreiben des Markers (#136)

    private static let failingWriter = MarkerWriter { _, _ in throw POSIXError(.ENOSPC) }

    @Test func failingMarkerKeepsTheAcquiredLock() throws {
        try withLockURL { url in
            guard case .acquired(let lock) = try InstanceLock.acquire(at: url, markerWriter: Self.failingWriter) else {
                Issue.record("Sperre trotz Markerfehler nicht erhalten")
                return
            }
            #expect(try InstanceLock.acquire(at: url) == .held(byTerminatingInstance: false))
            #expect(try InstanceLock.acquire(at: url, waitingUpTo: .milliseconds(100)) == nil)
            #expect(throws: POSIXError(.ENOSPC)) { try lock.markTerminating() }
            withExtendedLifetime(lock) {}
        }
    }

    @Test func waitingAcquireKeepsTheLockDespiteAFailingMarker() throws {
        try withLockURL { url in
            let lock = try #require(try InstanceLock.acquire(at: url, waitingUpTo: .zero, markerWriter: Self.failingWriter))
            #expect(try InstanceLock.acquire(at: url) == .held(byTerminatingInstance: false))
            withExtendedLifetime(lock) {}
        }
    }

    // MARK: - Modusbits der Sperrdatei (#136)

    @Test(arguments: [0o620, 0o666] as [mode_t])
    func refusesALockFileWritableByOthers(mode: mode_t) throws {
        try ScratchDirectory.withCanonical(prefix: "instance-lock") { directory in
            let url = directory.appending(path: "Instance.lock")
            try Self.foreignContents.write(to: url)
            try #require(chmod(url.path, mode) == 0)
            #expect(throws: InstanceLock.Refusal.modifiableByOthers) { try InstanceLock.acquire(at: url) }
            #expect(try Data(contentsOf: url) == Self.foreignContents)
        }
    }

    // MARK: - Veraltete Marker (#136)

    /// Marker einer Instanz, die nicht mehr läuft: eigene PID mit falscher Startzeit (PID neu vergeben), PID eines
    /// beendeten Kindprozesses; im älteren Format ohne Startzeit eine tote PID und ein anderes Programm (launchd).
    private static func staleTerminatingMarkers() throws -> [String] {
        let child = Process()
        child.executableURL = URL(filePath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let own = InstanceLockMarker.current(.terminating)
        return [
            InstanceLockMarker(state: .terminating, pid: own.pid, startTime: (own.startTime ?? 0) + 1).text,
            InstanceLockMarker(state: .terminating, pid: child.processIdentifier, startTime: own.startTime).text,
            "terminating \(child.processIdentifier)\n",
            "terminating 1\n",
        ]
    }

    @Test func staleTerminatingMarkerOfAHolderWhoseMarkerFailedIsNotReported() throws {
        for stale in try Self.staleTerminatingMarkers() {
            try withLockURL { url in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(stale.utf8).write(to: url)
                let holder = try InstanceLock.acquire(at: url, markerWriter: Self.failingWriter)
                #expect(try String(contentsOf: url, encoding: .utf8) == stale)
                #expect(try InstanceLock.acquire(at: url) == .held(byTerminatingInstance: false), "\(stale)")
                withExtendedLifetime(holder) {}
            }
        }
    }

    /// Update: Die ältere Version hält die Sperre und beendet sich noch (`terminating <PID>` ohne Startzeit); der neue
    /// Build muss auf sie warten. Der Halter ist hier dieser Prozess – lebend, mit demselben Programmnamen.
    @Test func legacyTerminatingMarkerOfALivingHolderIsReported() throws {
        try withLockURL { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let legacy = "terminating \(getpid())\n"
            try Data(legacy.utf8).write(to: url)
            let holder = try InstanceLock.acquire(at: url, markerWriter: Self.failingWriter)
            #expect(try String(contentsOf: url, encoding: .utf8) == legacy)
            #expect(try InstanceLock.acquire(at: url) == .held(byTerminatingInstance: true))
            withExtendedLifetime(holder) {}
        }
    }

    @Test func parsesCurrentAndLegacyMarkersOnly() {
        #expect(InstanceLockMarker(parsing: "terminating 42 7\n") == InstanceLockMarker(state: .terminating, pid: 42, startTime: 7))
        #expect(InstanceLockMarker(parsing: "running 42\n") == InstanceLockMarker(state: .running, pid: 42, startTime: nil))
        for invalid in ["", "terminating", "terminating x", "terminating 0", "terminating 42 x", "stopping 42 7", "terminating 42 7 9"] {
            #expect(InstanceLockMarker(parsing: invalid) == nil, "\(invalid)")
        }
    }

    @Test func interruptedTruncationIsRetriedAndOverwritesATerminatingMarker() throws {
        try withLockURL { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(InstanceLockMarker.current(.terminating).text.utf8).write(to: url)
            let interruptions = Mutex(1)
            let writer = MarkerWriter.file { descriptor, length in
                let interrupt = interruptions.withLock { remaining in
                    defer { remaining = max(remaining - 1, 0) }
                    return remaining > 0
                }
                guard !interrupt else {
                    errno = EINTR
                    return -1
                }
                return ftruncate(descriptor, length)
            }
            guard case .acquired(let lock) = try InstanceLock.acquire(at: url, markerWriter: writer) else {
                Issue.record("Sperre nicht erhalten")
                return
            }
            #expect(interruptions.withLock { $0 } == 0)
            #expect(try String(contentsOf: url, encoding: .utf8) == InstanceLockMarker.current(.running).text)
            #expect(try InstanceLock.acquire(at: url) == .held(byTerminatingInstance: false))
            withExtendedLifetime(lock) {}
        }
    }
}
