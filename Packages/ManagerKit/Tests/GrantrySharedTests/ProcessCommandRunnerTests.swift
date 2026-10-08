import Foundation
import Testing
@testable import GrantryShared
import TestSupport

@Suite struct ProcessCommandRunnerTests {
    let runner = ProcessCommandRunner()
    let clock = ContinuousClock()

    @Test func capturesStdoutAndExitCode() async throws {
        let result = try await runner.run("/bin/echo", ["hallo"])
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hallo\n")
        #expect(result.succeeded)
    }

    @Test func capturesStderrAndFailure() async throws {
        let result = try await runner.run("/bin/sh", ["-c", "echo fehler >&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.stderr == "fehler\n")
        #expect(!result.succeeded)
    }

    @Test func handlesLargeOutputWithoutDeadlock() async throws {
        let result = try await runner.run("/bin/sh", ["-c", "yes x | head -c 300000; yes y | head -c 300000 >&2"])
        #expect(result.stdout.count == 300_000)
        #expect(result.stderr.count == 300_000)
    }

    @Test func timesOutHangingProcess() async {
        await #expect(throws: CommandError.timedOut(executable: "/bin/sleep", seconds: 0.5)) {
            try await runner.run("/bin/sleep", ["10"], timeout: .milliseconds(500))
        }
    }

    @Test func reportsLaunchFailure() async {
        let error = await #expect(throws: CommandError.self) {
            try await runner.run("/nonexistent/binary", [])
        }
        guard case .launchFailed(let executable, _)? = error else {
            Issue.record("Erwartet launchFailed, erhalten: \(String(describing: error))")
            return
        }
        #expect(executable == "/nonexistent/binary")
    }

    @Test func returnsWithoutWaitingForTimeout() async throws {
        let elapsed = try await clock.measure {
            _ = try await runner.run("/bin/echo", ["schnell"], timeout: .seconds(60))
        }
        #expect(elapsed < .seconds(5))
    }

    @Test func providesNullDeviceAsStdin() async throws {
        let elapsed = try await clock.measure {
            let result = try await runner.run("/bin/cat", [], timeout: .seconds(2))
            #expect(result.exitCode == 0)
            #expect(result.stdout.isEmpty)
        }
        #expect(elapsed < .seconds(1))
    }

    @Test func killsChildThatIgnoresTermination() async {
        let runner = ProcessCommandRunner(terminationGracePeriod: .milliseconds(300))
        let elapsed = await clock.measure {
            await #expect(throws: CommandError.timedOut(executable: "/bin/sh", seconds: 0.3)) {
                try await runner.run("/bin/sh", ["-c", "trap '' TERM; exec sleep 5"], timeout: .milliseconds(300))
            }
        }
        #expect(elapsed < .seconds(3))
    }

    @Test func cancellationHonoursGracePeriodAndWaitsForExit() async throws {
        let runner = ProcessCommandRunner(terminationGracePeriod: .milliseconds(300))
        let marker = FileManager.default.temporaryDirectory.appending(path: "pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await runner.run(
                "/bin/sh", ["-c", "trap '' TERM; echo $$ > '\(marker.path)'; exec sleep 10"], timeout: .seconds(30)
            )
        }
        let pid = try await Self.waitForPID(in: marker)

        let elapsed = await clock.measure {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(elapsed >= .milliseconds(300), "Gnadenfrist vor SIGKILL muss auch bei Abbruch gelten")
        #expect(elapsed < .seconds(3))
        #expect(kill(pid, 0) == -1, "Prozess \(pid) muss beendet und abgeräumt sein, wenn run() zurückkehrt")
    }

    @Test func doesNotBlockOnDescendantHoldingPipeOpen() async {
        let elapsed = await clock.measure {
            await #expect(throws: CommandError.timedOut(executable: "/bin/sh", seconds: 0.5)) {
                try await runner.run("/bin/sh", ["-c", "echo vorher; sleep 2 &"], timeout: .milliseconds(500))
            }
        }
        #expect(elapsed < .seconds(3))
    }

    /// Wartet, bis der Kindprozess seine PID in `file` geschrieben hat.
    private static func waitForPID(in file: URL) async throws -> pid_t {
        for _ in 0..<500 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CommandError.launchFailed(executable: "/bin/sh", reason: "PID-Marker wurde nicht geschrieben")
    }
}

@Suite struct MockCommandRunnerTests {
    @Test func returnsStubsAndRecordsCalls() async throws {
        let mock = MockCommandRunner(["/bin/echo a": CommandResult(exitCode: 0, stdout: "a\n")])
        mock.stub("/bin/false", CommandResult(exitCode: 1, stdout: "", stderr: "nein"))

        let stubbed = try await mock.run("/bin/echo", ["a"])
        let added = try await mock.run("/bin/false", [])
        let unknown = try await mock.run("/bin/ls", ["-l"])

        #expect(stubbed == CommandResult(exitCode: 0, stdout: "a\n"))
        #expect(added.exitCode == 1)
        #expect(unknown.exitCode == 127)
        #expect(mock.calls == ["/bin/echo a", "/bin/false", "/bin/ls -l"])
    }

    @Test func durationFormatsGermanSeconds() {
        #expect(Duration.seconds(45).formattedSeconds == "45 s")
        #expect(Duration.milliseconds(200).formattedSeconds == "0,2 s")
    }
}
