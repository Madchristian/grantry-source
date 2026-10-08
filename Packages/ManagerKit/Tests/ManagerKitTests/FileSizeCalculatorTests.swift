import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct FileSizeCalculatorTests {
    private static let farFuture = ContinuousClock.now.advanced(by: .seconds(3_600))
    private static let calculator = FileSizeCalculator(timeout: .seconds(10))

    @Test func countsRegularFilesOfAFolder() throws {
        try ScratchDirectory.with(prefix: "size") { directory in
            try Data(count: 8_192).write(to: directory.appending(path: "a"))
            try FileManager.default.createDirectory(at: directory.appending(path: "sub"), withIntermediateDirectories: true)
            try Data(count: 4_096).write(to: directory.appending(path: "sub/b"))
            let size = FileSizeCalculator.measurement(of: directory.path, deadline: Self.farFuture) { false }
            let bytes = try #require(size.bytes)
            #expect(bytes >= 12_288 && bytes < 64 * 1_024)
            #expect(FileSizeCalculator().allocatedSize(of: directory.path) == bytes)
        }
    }

    /// Ein nicht lesbarer Unterordner (z. B. ohne Festplattenvollzugriff) macht die Größe „nicht lesbar“.
    @Test func unreadableSubfolderIsReported() throws {
        try ScratchDirectory.with(prefix: "size") { directory in
            let locked = directory.appending(path: "locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try Data(count: 4_096).write(to: locked.appending(path: "secret"))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            #expect(FileSizeCalculator.measurement(of: directory.path, deadline: Self.farFuture) { false } == .unreadable)
            #expect(FileSizeCalculator().allocatedSize(of: directory.path) == nil)
        }
    }

    @Test func missingPathIsUnknown() {
        let missing = "/nonexistent-\(UUID().uuidString)"
        #expect(FileSizeCalculator.measurement(of: missing, deadline: Self.farFuture) { false } == .unknown)
    }

    /// Abbruch beendet die Zählung (geprüft alle 256 Einträge).
    @Test func cancellationStopsCounting() throws {
        try ScratchDirectory.with(prefix: "size") { directory in
            for index in 0..<300 { try Data(count: 1).write(to: directory.appending(path: "f\(index)")) }
            #expect(FileSizeCalculator.measurement(of: directory.path, deadline: Self.farFuture) { true } == .unknown)
        }
    }

    @Test func cancelledTaskMeasuresNothing() async throws {
        try await ScratchDirectory.with(prefix: "size") { directory in
            let path = directory.path
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await FileSizeCalculator().measure(path)
            }
            #expect(await task.value == .unknown)
        }
    }

    /// Über Volume-Grenzen wird nicht gezählt: Einträge mit fremdem `st_dev` zählen nicht.
    @Test func otherVolumesDoNotCount() {
        let root = FileIdentity(device: 1, inode: 2, type: .directory)
        #expect(FileIdentity(device: 1, inode: 3, type: .regularFile).isOnSameVolume(as: root))
        #expect(!FileIdentity(device: 9, inode: 3, type: .regularFile).isOnSameVolume(as: root))
    }

    @Test func defaultMeasureUsesAllocatedSize() async {
        struct Fixed: FileSizeMeasuring {
            let value: Int64?
            func allocatedSize(of path: String) -> Int64? { value }
        }
        #expect(await Fixed(value: 5).measure("/x") == .bytes(5))
        #expect(await Fixed(value: nil).measure("/x") == .unknown)
    }

    @Test func sumsRegularFilesWithoutFollowingSymlinks() throws {
        try ScratchDirectory.with(prefix: "size") { directory in
            let folder = directory.appending(path: "Bundle.app/Contents")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<3 { try Data(count: 100_000).write(to: folder.appending(path: "file\(index)")) }
            let outside = directory.appending(path: "big")
            try Data(count: 5_000_000).write(to: outside)
            try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link").path, withDestinationPath: outside.path)
            let size = try #require(Self.calculator.allocatedSize(of: directory.appending(path: "Bundle.app").path))
            #expect(size >= 300_000)
            #expect(size < 5_000_000)
        }
    }

    @Test func regularFileAndMissingPath() throws {
        try ScratchDirectory.with(prefix: "size") { directory in
            let file = directory.appending(path: "a.plist")
            try Data(count: 10_000).write(to: file)
            #expect((Self.calculator.allocatedSize(of: file.path) ?? 0) >= 10_000)
            #expect(Self.calculator.allocatedSize(of: directory.appending(path: "missing").path) == nil)
        }
    }

    /// Die Zählung öffnet keine Dateien – eine FIFO im Ordner blockiert nicht.
    @Test func fifoInsideDoesNotBlock() async throws {
        try await ScratchDirectory.with(prefix: "size") { directory in
            let fifo = try FIFOFixture.make(in: directory)
            let path = directory.path
            let result = await FIFOFixture.completes(unblocking: fifo) { Self.calculator.allocatedSize(of: path) != nil }
            #expect(result == true)
        }
    }

    @Test func expiredDeadlineStopsCounting() throws {
        try ScratchDirectory.with(prefix: "size") { directory in
            for index in 0..<300 { try Data([1]).write(to: directory.appending(path: "f\(index)")) }
            let past = ContinuousClock.now.advanced(by: .seconds(-1))
            #expect(FileSizeCalculator.measurement(of: directory.path, deadline: past) { false } == .unknown)
        }
    }

    /// Review N2: Die Messung wartet auf einer eigenen Queue, nicht im kooperativen Pool – auch viel mehr gleichzeitige
    /// Messungen, als der Pool Threads hat, halten andere Tasks nicht an.
    @Test(.timeLimit(.minutes(1))) func blockingMeasurementsDoNotStallTheCooperativePool() async {
        let latch = Latch()
        let calculator = FileSizeCalculator(timeout: .seconds(30), callGuard: BlockingCallGuard(maximumHanging: 1)) { _, _, _ in
            latch.wait()
            return .bytes(1)
        }
        let count = ProcessInfo.processInfo.activeProcessorCount + 4
        let measurements = (0..<count).map { index in Task.detached { await calculator.measure("/x\(index)") } }
        try? await Task.sleep(for: .milliseconds(100))

        let start = ContinuousClock.now
        let other = await Task.detached { 42 }.value
        #expect(other == 42)
        #expect(ContinuousClock.now - start < .seconds(1), "der Pool ist frei")

        latch.release(count)
        for measurement in measurements { #expect(await measurement.value == .bytes(1)) }
    }

    /// Der Abbruch des wartenden Tasks erreicht die laufende Zählung.
    @Test(.timeLimit(.minutes(1))) func cancellationReachesTheRunningMeasurement() async {
        let started = Latch()
        let calculator = FileSizeCalculator(timeout: .seconds(30), callGuard: BlockingCallGuard(maximumHanging: 1)) { _, _, isCancelled in
            started.release()
            while !isCancelled() { Thread.sleep(forTimeInterval: 0.005) }
            return .unknown
        }
        let task = Task.detached { await calculator.measure("/x") }
        await onOwnThread { started.wait() }  // die Messung läuft auf der Queue des Rechners, nicht im Pool
        task.cancel()
        #expect(await task.value == .unknown)
    }
}
