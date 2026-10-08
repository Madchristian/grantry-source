import Darwin
import Foundation
import Testing
@testable import GrantryShared

/// Prüft den Scanner an eigenen Sockets dieses Testprozesses (nur Loopback, kein Systemeingriff, im Test geschlossen).
@Suite(.serialized) struct LibprocSocketEnumeratorTests {
    /// Ein im Test geöffneter Socket mit seinem vom System gewählten lokalen Port.
    private struct TestSocket {
        let fd: Int32
        let port: UInt16
    }

    /// Öffnet einen Socket, bindet ihn an `address` mit vom System gewähltem Port – oder mit dem ersten freien Port aus
    /// `explicitPortIn` – und lässt ihn optional lauschen bzw. verbindet ihn (UDP) mit `peerPort` auf derselben
    /// Adresse. Schließt den Deskriptor, wenn ein Schritt scheitert.
    private func openSocket(_ type: Int32, on address: String, scope: String? = nil, listening: Bool = false,
                            connectingTo peerPort: UInt16? = nil,
                            explicitPortIn candidates: ClosedRange<UInt16>? = nil) throws -> TestSocket {
        var storage = sockaddr_storage()
        let family = try fill(&storage, address: address, scope: scope)
        let fd = socket(family, type, 0)
        try #require(fd >= 0)
        do {
            var length = socklen_t(storage.ss_len)
            if let candidates {
                try #require(candidates.contains { port in
                    setPort(port, in: &storage)
                    return withSockaddr(&storage) { bind(fd, $0, length) } == 0
                }, "kein freier Port in \(candidates)")
            } else {
                try #require(withSockaddr(&storage) { bind(fd, $0, length) } == 0)
            }
            if listening { try #require(listen(fd, 1) == 0) }
            if let peerPort {
                var peer = storage
                setPort(peerPort, in: &peer)
                try #require(withSockaddr(&peer) { connect(fd, $0, length) } == 0)
            }
            try #require(withSockaddr(&storage) { getsockname(fd, $0, &length) } == 0)
            return TestSocket(fd: fd, port: port(of: storage))
        } catch {
            close(fd)
            throw error
        }
    }

    private func fill(_ storage: inout sockaddr_storage, address: String, scope: String?) throws -> Int32 {
        if address.contains(":") {
            return try withUnsafeMutablePointer(to: &storage) { pointer in
                try pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet6 in
                    inet6.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    inet6.pointee.sin6_family = sa_family_t(AF_INET6)
                    inet6.pointee.sin6_scope_id = scope.map { if_nametoindex($0) } ?? 0
                    try #require(inet_pton(AF_INET6, address, &inet6.pointee.sin6_addr) == 1)
                    return AF_INET6
                }
            }
        }
        return try withUnsafeMutablePointer(to: &storage) { pointer in
            try pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                inet.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                inet.pointee.sin_family = sa_family_t(AF_INET)
                try #require(inet_pton(AF_INET, address, &inet.pointee.sin_addr) == 1)
                return AF_INET
            }
        }
    }

    private func withSockaddr<Result>(_ storage: inout sockaddr_storage,
                                      _ body: (UnsafeMutablePointer<sockaddr>) -> Result) -> Result {
        withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body) }
    }

    /// `sin_port` und `sin6_port` liegen an derselben Stelle (nach Länge und Familie).
    private func setPort(_ port: UInt16, in storage: inout sockaddr_storage) {
        withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port = port.bigEndian }
        }
    }

    private func port(of storage: sockaddr_storage) -> UInt16 {
        var copy = storage
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
    }

    /// Eigene gelistete Sockets auf `port`.
    private func ownSockets(on port: UInt16) throws -> [ListeningSocket] {
        try LibprocSocketEnumerator().listeningSockets().sockets.filter { $0.pid == getpid() && $0.localPort == port }
    }

    @Test func findsOwnLoopbackListener() throws {
        let socket = try openSocket(SOCK_STREAM, on: "127.0.0.1", listening: true)
        defer { close(socket.fd) }
        let own = try ownSockets(on: socket.port)
        #expect(own.count == 1)
        #expect(own.first?.transport == .tcp)
        #expect(own.first?.localAddress == "127.0.0.1")
        #expect(own.first?.uid == getuid())
        #expect(own.first?.executablePath.isEmpty == false)
    }

    /// Der Socket trägt die Startzeit seines Besitzers (#153, Befund 2) – dieselbe wie `LibprocProcessInspector`.
    @Test func socketCarriesTheOwnersStartTime() throws {
        let socket = try openSocket(SOCK_STREAM, on: "127.0.0.1", listening: true)
        defer { close(socket.fd) }
        let me = try #require(LibprocProcessInspector().process(getpid()))
        let own = try ownSockets(on: socket.port)
        #expect(own.map(\.startTime) == [me.startTime])
        #expect(own.first?.belongs(to: me) == true)
    }

    @Test func findsOwnIPv6LoopbackListener() throws {
        let socket = try openSocket(SOCK_STREAM, on: "::1", listening: true)
        defer { close(socket.fd) }
        let own = try ownSockets(on: socket.port)
        #expect(own.map(\.localAddress) == ["::1"])
        #expect(own.first?.transport == .tcp)
    }

    /// libproc bettet die Scope-ID link-lokaler Adressen in die Adresse ein (KAME); sie darf nicht im Text landen.
    @Test func linkLocalAddressHasNoEmbeddedScope() throws {
        let socket = try openSocket(SOCK_STREAM, on: "fe80::1", scope: "lo0", listening: true)
        defer { close(socket.fd) }
        #expect(try ownSockets(on: socket.port).map(\.localAddress) == ["fe80::1"])
    }

    @Test func findsOwnBoundUDPSocket() throws {
        let socket = try openSocket(SOCK_DGRAM, on: "127.0.0.1")
        defer { close(socket.fd) }
        let own = try ownSockets(on: socket.port)
        #expect(own.map(\.transport) == [.udp])
        #expect(own.first?.localAddress == "127.0.0.1")
    }

    /// Vom System gewählter Port (`bind(0)`): Der Kernel setzt `INP_ANONPORT`.
    @Test func systemAssignedPortIsFlagged() throws {
        let udp = try openSocket(SOCK_DGRAM, on: "127.0.0.1")
        defer { close(udp.fd) }
        let tcp = try openSocket(SOCK_STREAM, on: "127.0.0.1", listening: true)
        defer { close(tcp.fd) }
        #expect(try ownSockets(on: udp.port).map(\.hasSystemAssignedPort) == [true])
        #expect(try ownSockets(on: tcp.port).map(\.hasSystemAssignedPort) == [true])
    }

    /// Ausdrücklich gewählter Port im Ephemeralbereich (wie WireGuard auf 51820): kein `INP_ANONPORT`, obwohl der Port
    /// im Bereich liegt, den `bind(0)` sonst nutzt.
    @Test func explicitlyChosenPortIsNotFlagged() throws {
        let socket = try openSocket(SOCK_DGRAM, on: "127.0.0.1", explicitPortIn: 60000...60099)
        defer { close(socket.fd) }
        #expect(try ownSockets(on: socket.port).map(\.hasSystemAssignedPort) == [false])
    }

    /// Einzelprüfung je PID (`ListeningProcessChecking`): dieser Prozess mit offenem Lauscher ja, ein eigener
    /// `/bin/sleep` ohne Sockets nein.
    @Test func checksWhetherAProcessIsListening() throws {
        let socket = try openSocket(SOCK_STREAM, on: "127.0.0.1", listening: true)
        defer { close(socket.fd) }
        #expect(LibprocSocketEnumerator().isListening(getpid()))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        #expect(!LibprocSocketEnumerator().isListening(child.processIdentifier))
    }

    @Test func closedListenerIsNotListed() throws {
        let socket = try openSocket(SOCK_STREAM, on: "127.0.0.1", listening: true)
        close(socket.fd)
        #expect(try ownSockets(on: socket.port).isEmpty)
    }

    @Test func boundButNotListeningTCPSocketIsNotListed() throws {
        let socket = try openSocket(SOCK_STREAM, on: "127.0.0.1")
        defer { close(socket.fd) }
        #expect(try ownSockets(on: socket.port).isEmpty)
    }

    @Test func connectedUDPSocketIsNotListed() throws {
        let socket = try openSocket(SOCK_DGRAM, on: "127.0.0.1", connectingTo: 9)
        defer { close(socket.fd) }
        #expect(try ownSockets(on: socket.port).isEmpty)
    }

    @Test func onlyAccessDenialCountsAsDenied() {
        #expect(LibprocSocketEnumerator.descriptorFailure(errno: EPERM) == .denied)
        #expect(LibprocSocketEnumerator.descriptorFailure(errno: EACCES) == .denied)
        #expect(LibprocSocketEnumerator.descriptorFailure(errno: ESRCH) == .unavailable)
        #expect(LibprocSocketEnumerator.descriptorFailure(errno: 0) == .unavailable)
    }

    @Test(.enabled(if: getuid() != 0, "Als root ist jeder Prozess lesbar."))
    func foreignProcessesCountAsDeniedForUsers() throws {
        #expect(try LibprocSocketEnumerator().listeningSockets().deniedProcessCount > 0)
    }

    @Test func socketsRoundTripThroughJSON() throws {
        let scan = ListeningSocketScan(sockets: [ListeningSocket(
            pid: 42, uid: 0, executablePath: "/usr/sbin/sshd", transport: .tcp, localAddress: "::", localPort: 22,
            ancestors: ["/usr/libexec/sshd-keygen-wrapper"], startTime: 1_700_000_000_000_000,
            hasSystemAssignedPort: false
        )], deniedProcessCount: 3)
        let data = try JSONEncoder().encode(scan)
        #expect(try JSONDecoder().decode(ListeningSocketScan.self, from: data) == scan)
    }

    /// Ein Scan eines älteren Helpers (Protokoll ≤ 4) ohne Startzeit und Port-Flag bleibt lesbar; seine Sockets gehören
    /// zu keinem Prozess, die Herkunft des Ports ist unbekannt.
    @Test func scanWithoutStartTimeIsReadableButOwnerless() throws {
        let json = """
        {"sockets":[{"pid":42,"uid":0,"executablePath":"/usr/sbin/sshd","transport":"tcp","localAddress":"::",
        "localPort":22,"ancestors":[]}],"deniedProcessCount":0}
        """
        let scan = try JSONDecoder().decode(ListeningSocketScan.self, from: Data(json.utf8))
        let socket = try #require(scan.sockets.first)
        #expect(socket.startTime == nil)
        #expect(socket.hasSystemAssignedPort == nil)
        #expect(socket.localPort == 22)
        #expect(!socket.belongs(to: RunningProcess(pid: 42, uid: 0, executablePath: "/usr/sbin/sshd", startTime: 1)))
    }

    /// Zugehörigkeit nur bei derselben Generation: gleiche PID, Benutzer und Programm, aber andere Startzeit – ein
    /// neuer Prozess (#153, Befund 2).
    @Test func socketBelongsOnlyToTheSameGeneration() {
        let socket = ListeningSocket(pid: 42, uid: 0, executablePath: "/usr/sbin/sshd", transport: .tcp, localAddress: "::",
                                     localPort: 22, startTime: 1_000)
        #expect(socket.belongs(to: RunningProcess(pid: 42, uid: 0, executablePath: "/usr/sbin/sshd", startTime: 1_000)))
        #expect(!socket.belongs(to: RunningProcess(pid: 42, uid: 0, executablePath: "/usr/sbin/sshd", startTime: 2_000)))
        #expect(!socket.belongs(to: RunningProcess(pid: 42, uid: 501, executablePath: "/usr/sbin/sshd", startTime: 1_000)))
        #expect(!socket.belongs(to: RunningProcess(pid: 42, uid: 0, executablePath: "/usr/local/sbin/sshd", startTime: 1_000)))
        #expect(!socket.belongs(to: RunningProcess(pid: 43, uid: 0, executablePath: "/usr/sbin/sshd", startTime: 1_000)))
    }
}
