import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct CleanupLogTests {
    private func outcome(_ index: Int) -> StorageCleanOutcome {
        StorageCleanOutcome(categoryID: "caches", target: "/x/\(index)", method: .delete, freedBytes: Int64(index),
                            result: .removed)
    }

    private func permissions(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func appendsAndReadsInOrder() throws {
        try ScratchDirectory.withCanonical(prefix: "cleanup-log") { scratch in
            let log = CleanupLog(url: scratch.appending(path: "sub/CleanupLog.jsonl"))
            try log.append([outcome(1), outcome(2)], at: Date(timeIntervalSince1970: 10))
            #expect(log.read().map(\.outcome) == [outcome(1), outcome(2)])
            #expect(log.read().first?.date == Date(timeIntervalSince1970: 10))
        }
    }

    @Test func keepsOnlyNewestEntries() throws {
        try ScratchDirectory.withCanonical(prefix: "cleanup-log") { scratch in
            let log = CleanupLog(url: scratch.appending(path: "CleanupLog.jsonl"), maximumEntries: 3)
            try log.append((1...5).map(outcome), at: .now)
            #expect(log.read().map(\.outcome.target) == ["/x/3", "/x/4", "/x/5"])
        }
    }

    @Test func skipsCorruptLines() throws {
        try ScratchDirectory.withCanonical(prefix: "cleanup-log") { scratch in
            let url = scratch.appending(path: "CleanupLog.jsonl")
            let log = CleanupLog(url: url)
            try log.append([outcome(1)], at: .now)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{kaputt\n".utf8))
            try handle.close()
            try log.append([outcome(2)], at: .now)
            #expect(log.read().map(\.outcome) == [outcome(1), outcome(2)])
            // Die beschädigte Zeile ist beim Schreiben verworfen worden.
            let raw = try String(contentsOf: url, encoding: .utf8)
            #expect(!raw.contains("kaputt"))
            #expect(raw.split(separator: "\n").count == 2)
        }
    }

    @Test func writesPrivateFileInPrivateDirectory() throws {
        try ScratchDirectory.withCanonical(prefix: "cleanup-log") { scratch in
            let url = scratch.appending(path: "Grantry/CleanupLog.jsonl")
            try CleanupLog(url: url).append([outcome(1)], at: .now)
            #expect(try permissions(of: url) == 0o600)
            #expect(try permissions(of: url.deletingLastPathComponent()) == 0o700)
        }
    }

    @Test func existingWorldReadableLogBecomesPrivateWhenRewritten() throws {
        try ScratchDirectory.withCanonical(prefix: "cleanup-log") { scratch in
            let folder = scratch.appending(path: "Grantry", directoryHint: .isDirectory)
            let url = folder.appending(path: "CleanupLog.jsonl")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try CleanupLog(url: url).append([outcome(1)], at: .now)
            #expect(try permissions(of: url) == 0o600)
            #expect(try permissions(of: folder) == 0o700)
        }
    }

    @Test func missingFileReadsEmpty() {
        #expect(CleanupLog(url: URL(filePath: "/nonexistent-\(UUID().uuidString)/log.jsonl")).read().isEmpty)
    }
}
