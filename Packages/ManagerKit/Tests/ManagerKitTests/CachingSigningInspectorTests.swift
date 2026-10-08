import Foundation
import Testing
@testable import ManagerKit
import TestSupport

@Suite struct CachingSigningInspectorTests {
    @Test func inspectsEachUnchangedPathOnce() throws {
        try ScratchDirectory.with(prefix: "caching-signing") { directory in
            let program = directory.appending(path: "tool")
            try Data("x".utf8).write(to: program)
            let recording = RecordingSigningInspector(result: SigningInfo(kind: .adHoc))
            let inspector = CachingSigningInspector(inspector: recording)

            #expect(inspector.inspect(path: program.path) == SigningInfo(kind: .adHoc))
            #expect(inspector.inspect(path: program.path) == SigningInfo(kind: .adHoc))
            #expect(recording.paths.count == 1)
        }
    }

    @Test func changedFingerprintInvalidatesTheEntry() throws {
        try ScratchDirectory.with(prefix: "caching-signing") { directory in
            let program = directory.appending(path: "tool")
            try Data("x".utf8).write(to: program)
            let recording = RecordingSigningInspector(result: .unknown)
            let inspector = CachingSigningInspector(inspector: recording)

            _ = inspector.inspect(path: program.path)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: program.path
            )
            _ = inspector.inspect(path: program.path)
            #expect(recording.paths.count == 2)
        }
    }

    @Test func missingPathsAreInspectedEveryTime() {
        let recording = RecordingSigningInspector(result: .unknown)
        let inspector = CachingSigningInspector(inspector: recording)
        _ = inspector.inspect(path: "/does/not/exist")
        _ = inspector.inspect(path: "/does/not/exist")
        #expect(recording.paths == ["/does/not/exist", "/does/not/exist"])
    }

    @Test func symlinksAreInspectedAtTheirTarget() throws {
        try ScratchDirectory.with(prefix: "caching-signing") { directory in
            let target = directory.appending(path: "tool")
            try Data("x".utf8).write(to: target)
            let link = directory.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let recording = RecordingSigningInspector(result: .unknown)

            _ = CachingSigningInspector(inspector: recording).inspect(path: link.path)
            #expect(recording.paths == [target.resolvingSymlinksInPath().path])
        }
    }

    /// Eine Zeitüberschreitung ist kein Ergebnis (Review M1): Der nächste Scan prüft erneut, statt `.unknown` bis
    /// zum nächsten Update zu behalten.
    @Test func timeoutIsNotCached() throws {
        try ScratchDirectory.with(prefix: "caching-signing") { directory in
            let program = directory.appending(path: "tool")
            try Data("x".utf8).write(to: program)
            let scripted = ScriptedSigningInspector([.timedOut, .completed(SigningInfo(kind: .adHoc))])
            let inspector = CachingSigningInspector(inspector: scripted)

            #expect(inspector.inspection(ofPath: program.path) == .timedOut)
            #expect(inspector.inspect(path: program.path) == SigningInfo(kind: .adHoc))
            #expect(inspector.inspect(path: program.path) == SigningInfo(kind: .adHoc))
            #expect(scripted.calls == 2)
        }
    }

    /// Ein echtes `.unknown` (z. B. beschädigte Signatur) bleibt gemerkt.
    @Test func conclusiveUnknownIsCached() throws {
        try ScratchDirectory.with(prefix: "caching-signing") { directory in
            let program = directory.appending(path: "tool")
            try Data("x".utf8).write(to: program)
            let scripted = ScriptedSigningInspector([.completed(.unknown)])
            let inspector = CachingSigningInspector(inspector: scripted)
            _ = inspector.inspect(path: program.path)
            #expect(inspector.inspection(ofPath: program.path) == .completed(.unknown))
            #expect(scripted.calls == 1)
        }
    }
}
