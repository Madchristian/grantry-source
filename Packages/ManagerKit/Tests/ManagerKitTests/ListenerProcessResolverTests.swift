import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ListenerProcessResolverTests {
    private final class Provider: ListeningSocketProviding {
        private let scan: ListeningSocketScan
        private let count = Mutex(0)
        init(_ sockets: [ListeningSocket]) { scan = ListeningSocketScan(sockets: sockets) }
        var calls: Int { count.withLock { $0 } }
        func listeningSockets() async throws -> ListeningSocketScan {
            count.withLock { $0 += 1 }
            return scan
        }
    }

    /// Startzeit des Prozesses `pid` in den Fakes.
    private static func startTime(_ pid: Int32) -> UInt64 { UInt64(pid) * 1_000 }

    /// Socket des Prozesses `pid` – mit dessen Startzeit, wie der Enumerator sie liefert.
    private func socket(_ pid: Int32, uid: UInt32 = 501, path: String = "/opt/homebrew/bin/node",
                        _ transport: SocketTransport = .tcp, _ address: String = "0.0.0.0",
                        _ port: UInt16 = 3000, startTime: UInt64? = nil) -> ListeningSocket {
        ListeningSocket(pid: pid, uid: uid, executablePath: path, transport: transport, localAddress: address, localPort: port,
                        startTime: startTime ?? Self.startTime(pid))
    }

    private static func process(_ pid: Int32, uid: UInt32 = 501, path: String = "/opt/homebrew/bin/node") -> RunningProcess {
        RunningProcess(pid: pid, uid: uid, executablePath: path, startTime: startTime(pid))
    }

    /// Prozesse wie in den Sockets – jede PID läuft mit dem Programm und Benutzer ihres Sockets.
    private static let running = [10, 11, 12, 13, 20, 21].map { process($0) } + [
        process(14, path: "/usr/local/bin/other"), process(15, uid: 502), process(30, uid: 0, path: "/usr/local/sbin/daemon"),
    ]

    private func resolver(
        local: [ListeningSocket] = [], provider: Provider? = nil, processes: [RunningProcess] = Self.running,
        unconfirmed: Set<pid_t> = []
    ) -> ListenerProcessResolver {
        ListenerProcessResolver(provider: provider, local: FixedSockets(result: .success(ListeningSocketScan(sockets: local))),
                                inspector: FixedProcessInspector(processes, unconfirmed: unconfirmed), currentUID: 501)
    }

    /// #153, Codex-Runde 3: Läuft der Prozess des Sockets noch (PID und Startzeit), ist aber seine Identität gerade
    /// nicht bestätigt (`exec` zwischen den Token-Lesungen), fällt er nicht still weg – sonst könnte das Beenden der
    /// übrigen Prozesse den Lauscher als beendet vermerken. Die Auflösung scheitert verständlich.
    @Test func unconfirmedRunningProcessFailsInsteadOfBeingDropped() async {
        await #expect(throws: ProcessTerminationViolation.identityUnknown(10)) {
            try await resolver(local: [socket(10), socket(11)], unconfirmed: [10]).request(for: TestData.listener())
        }
    }

    @Test func findsEveryProcessOfTheGroupOnce() async throws {
        let listener = TestData.listener()
        let request = try await resolver(local: [
            socket(11, .tcp, "0.0.0.0"), socket(11, .tcp, "::"), socket(10, .tcp, "::"),
            socket(12, .udp), socket(13, .tcp, "0.0.0.0", 3001), socket(14, path: "/usr/local/bin/other"), socket(15, uid: 502),
        ]).request(for: listener)
        #expect(request.listener == listener)
        #expect(request.processes == [Self.process(10), Self.process(11)])
    }

    /// Zwischen Socket und Prozess beendet oder mit anderem Programm/Benutzer neu belegt: kein Ziel.
    @Test func dropsProcessesThatNoLongerMatchTheirSocket() async throws {
        let request = try await resolver(local: [socket(10), socket(11), socket(12)], processes: [
            Self.process(11, path: "/usr/local/bin/other"), Self.process(12, uid: 502),
        ]).request(for: TestData.listener())
        #expect(request.processes.isEmpty)
    }

    /// #153, Befund 2: Der Prozess des Sockets endet, ein neuer Prozess desselben Programms und Benutzers bekommt die
    /// PID (andere Startzeit) – er ist nicht der Dienst, den der Socket belegt, und wird kein Ziel.
    @Test func dropsANewProcessOfTheSameProgramUnderTheSocketsPID() async throws {
        let socketOfEndedProcess = socket(10, startTime: Self.startTime(10) - 1)
        let request = try await resolver(local: [socketOfEndedProcess, socket(11)]).request(for: TestData.listener())
        #expect(request.processes == [Self.process(11)])
    }

    /// Sockets eines älteren Helpers ohne Startzeit lassen sich keinem Prozess sicher zuordnen: kein Ziel.
    @Test func socketsWithoutStartTimeHaveNoTarget() async throws {
        let legacy = ListeningSocket(pid: 10, uid: 501, executablePath: "/opt/homebrew/bin/node", transport: .tcp,
                                     localAddress: "0.0.0.0", localPort: 3000)
        #expect(try await resolver(local: [legacy]).request(for: TestData.listener()).processes.isEmpty)
    }

    /// Wie in der Anzeige: Ports im Ephemeralbereich gehören zum Lauscher „wechselnd“.
    @Test func ephemeralPortsMatchTheVariableListener() async throws {
        let listener = TestData.listener(port: nil, addresses: ["127.0.0.1"])
        let request = try await resolver(local: [socket(20, .tcp, "127.0.0.1", 61086), socket(21, .tcp, "127.0.0.1", 3000)])
            .request(for: listener)
        #expect(request.processes.map(\.pid) == [20])
    }

    @Test func vanishedListenerHasNoProcesses() async throws {
        #expect(try await resolver().request(for: TestData.listener()).processes.isEmpty)
    }

    @Test func foreignListenerIsResolvedOverTheHelper() async throws {
        let root = TestData.listener("/usr/local/sbin/daemon", uid: 0, port: 22)
        let provider = Provider([socket(30, uid: 0, path: "/usr/local/sbin/daemon", .tcp, "0.0.0.0", 22)])
        let request = try await resolver(provider: provider).request(for: root)
        #expect(request.processes == [Self.process(30, uid: 0, path: "/usr/local/sbin/daemon")])
        #expect(provider.calls == 1)
    }

    @Test func ownListenerDoesNotAskTheHelper() async throws {
        let provider = Provider([])
        _ = try await resolver(local: [socket(10)], provider: provider).request(for: TestData.listener())
        #expect(provider.calls == 0)
    }

    @Test func foreignListenerWithoutHelperIsRejected() async {
        await #expect(throws: ProcessTerminationError.helperRequired) {
            _ = try await resolver().request(for: TestData.listener("/usr/local/sbin/daemon", uid: 0))
        }
    }
}
