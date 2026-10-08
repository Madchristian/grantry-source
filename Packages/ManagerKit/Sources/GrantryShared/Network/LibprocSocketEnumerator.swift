import Darwin
import Foundation

/// Liest lauschende Sockets über libproc, ohne einen Prozess zu starten. Als Benutzer sind nur eigene Prozesse lesbar,
/// als root (Helper) alle. Prozesse, die während des Durchlaufs enden oder nicht lesbar sind, werden übersprungen; nur
/// verweigerter Zugriff zählt in `deniedProcessCount`.
///
/// Auswahl: TCP im Zustand `LISTEN`; UDP mit lokalem Port und ohne entfernten Port (nicht verbunden). Nur IPv4/IPv6.
///
/// Jeder Socket wird seinem Besitzer samt Startzeit zugeordnet (`ListeningSocket.startTime`). Damit Sockets und Prozess
/// zur selben Generation gehören, wird die Prozessgeneration (`ProcessAuditToken`) vor dem Lesen der Deskriptoren
/// festgehalten und muss mit der des danach gelesenen Prozesses übereinstimmen; sonst wurde die PID zwischendurch neu
/// vergeben, und der Prozess wird übersprungen (#153, Befund 2).
public struct LibprocSocketEnumerator: ListeningSocketEnumerating, ListeningProcessChecking {
    /// Höchstzahl der Glieder der Elternkette.
    static let maximumAncestors = 16

    public init() {}

    public func listeningSockets() throws -> ListeningSocketScan {
        var processes = ProcessTable()
        var sockets: [ListeningSocket] = []
        var denied = 0
        for pid in try Self.allPIDs() {
            let generation = ProcessAuditToken(pid: pid)
            let descriptors: [Int32]
            switch Self.socketDescriptors(of: pid) {
            case .readable(let read): descriptors = read
            case .denied: denied += 1; continue
            case .unavailable: continue
            }
            let found = descriptors.compactMap { Self.listeningSocket(pid: pid, fd: $0) }
            guard !found.isEmpty, let generation, let info = processes.info(pid), info.process.auditToken == generation
            else { continue }
            let ancestors = processes.ancestors(of: pid, limit: Self.maximumAncestors)
            sockets += found.map { raw in
                ListeningSocket(pid: pid, uid: info.process.uid, executablePath: info.process.executablePath,
                                transport: raw.transport, localAddress: raw.address, localPort: raw.port,
                                ancestors: ancestors, startTime: info.process.startTime,
                                hasSystemAssignedPort: raw.hasSystemAssignedPort)
            }
        }
        return ListeningSocketScan(sockets: sockets, deniedProcessCount: denied)
    }

    /// Einzelprüfung ohne Durchlauf aller Prozesse; nicht lesbare Deskriptoren zählen als „lauscht nicht“.
    public func isListening(_ pid: pid_t) -> Bool {
        guard case .readable(let descriptors) = Self.socketDescriptors(of: pid) else { return false }
        return descriptors.contains { Self.listeningSocket(pid: pid, fd: $0) != nil }
    }

    // MARK: - libproc

    private static func allPIDs() throws -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { throw ListeningSocketError(code: errno) }
        // Puffer mit Reserve: zwischen den Aufrufen können Prozesse hinzukommen.
        var buffer = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = buffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { throw ListeningSocketError(code: errno) }
        // Ein bis zum Rand gefüllter Puffer könnte gekürzt sein; dank der Reserve von 64 PIDs kommt das praktisch nicht
        // vor, und ein dazwischen gestarteter Prozess wird spätestens im nächsten Durchlauf erfasst.
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// Ergebnis des Lesens der Deskriptoren eines Prozesses.
    enum DescriptorAccess: Equatable {
        /// Socket-Deskriptoren des Prozesses.
        case readable([Int32])
        /// Zugriff verweigert (fremder Benutzer ohne root).
        case denied
        /// Nicht lesbar aus anderem Grund: beendet, Zombie, keine Deskriptoren.
        case unavailable
    }

    /// Einordnung eines gescheiterten `PROC_PIDLISTFDS`: nur `EPERM`/`EACCES` gelten als verweigert.
    static func descriptorFailure(errno code: Int32) -> DescriptorAccess {
        code == EPERM || code == EACCES ? .denied : .unavailable
    }

    private static func socketDescriptors(of pid: pid_t) -> DescriptorAccess {
        let size = listDescriptors(of: pid, into: nil, capacity: 0)
        guard size > 0 else { return descriptorFailure(errno: errno) }
        // Reserve: zwischen den Aufrufen kann der Prozess weitere Deskriptoren öffnen.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(),
                                        count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
        let read = descriptors.withUnsafeMutableBytes { listDescriptors(of: pid, into: $0.baseAddress, capacity: $0.count) }
        guard read > 0 else { return descriptorFailure(errno: errno) }
        return .readable(descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.size)
            .filter { $0.proc_fdtype == PROX_FDTYPE_SOCKET }
            .map(\.proc_fd))
    }

    /// `PROC_PIDLISTFDS` mit zurückgesetztem `errno`, damit kein Fehler eines früheren Aufrufs mitgezählt wird.
    private static func listDescriptors(of pid: pid_t, into buffer: UnsafeMutableRawPointer?, capacity: Int) -> Int32 {
        errno = 0
        return proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, Int32(capacity))
    }

    /// Rohdaten eines lauschenden Sockets (Struct statt Tupel, Leitplanke 2).
    private struct RawSocket {
        let transport: SocketTransport
        let address: String
        let port: UInt16
        /// `INP_ANONPORT` in `insi_flags`: Der Kernel hat den Port bei `bind(0)` gewählt.
        let hasSystemAssignedPort: Bool
    }

    private static func listeningSocket(pid: pid_t, fd: Int32) -> RawSocket? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        let family = info.psi.soi_family
        guard family == AF_INET || family == AF_INET6 else { return nil }
        switch Int(info.psi.soi_kind) {
        case Int(SOCKINFO_TCP):
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
            return raw(.tcp, tcp.tcpsi_ini)
        case Int(SOCKINFO_IN):
            let inet = info.psi.soi_proto.pri_in
            guard info.psi.soi_protocol == IPPROTO_UDP, port(inet.insi_fport) == 0, port(inet.insi_lport) != 0 else {
                return nil
            }
            return raw(.udp, inet)
        default:
            return nil
        }
    }

    private static func raw(_ transport: SocketTransport, _ inet: in_sockinfo) -> RawSocket {
        RawSocket(transport: transport, address: address(of: inet), port: port(inet.insi_lport),
                  hasSystemAssignedPort: inet.insi_flags & UInt32(INP_ANONPORT) != 0)
    }

    private static func port(_ value: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: value))
    }

    private static func address(of inet: in_sockinfo) -> String {
        if inet.insi_vflag & UInt8(INI_IPV6) != 0 {
            return numeric(inet.insi_laddr.ina_6)
        }
        return numeric(inet.insi_laddr.ina_46.i46a_addr4)
    }

    private static func numeric(_ address: in_addr) -> String {
        withUnsafeBytes(of: address) { numeric(AF_INET, $0, length: INET_ADDRSTRLEN) }
    }

    /// IPv6-Adresse ohne die vom Kernel eingebettete Scope-ID (KAME: Bytes 2–3 bei link- bzw. interface-lokalen
    /// Adressen), damit z. B. `fe80::1` statt `fe80:1::1` herauskommt.
    private static func numeric(_ address: in6_addr) -> String {
        var address = address
        withUnsafeMutableBytes(of: &address) { bytes in
            let linkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
            let localMulticast = bytes[0] == 0xFF && (bytes[1] & 0x0F == 0x01 || bytes[1] & 0x0F == 0x02)
            if linkLocal || localMulticast {
                bytes[2] = 0
                bytes[3] = 0
            }
        }
        return withUnsafeBytes(of: address) { numeric(AF_INET6, $0, length: INET6_ADDRSTRLEN) }
    }

    private static func numeric(_ family: Int32, _ bytes: UnsafeRawBufferPointer, length: Int32) -> String {
        var text = [CChar](repeating: 0, count: Int(length))
        guard inet_ntop(family, bytes.baseAddress, &text, socklen_t(text.count)) != nil else { return "" }
        return text.nullTerminatedString
    }
}

/// Prozessinformationen eines Durchlaufs, je PID einmal gelesen: der Prozess laut `LibprocProcessInspector` (Benutzer,
/// Programm, Startzeit, Generation) und sein Elternprozess.
private struct ProcessTable {
    struct Info {
        let process: RunningProcess
        let parent: pid_t
    }

    private let inspector = LibprocProcessInspector()
    private var cache: [pid_t: Info?] = [:]

    mutating func info(_ pid: pid_t) -> Info? {
        if let cached = cache[pid] { return cached }
        let info = read(pid)
        cache[pid] = info
        return info
    }

    /// Programmpfade der Eltern, nächster zuerst, bis ausschließlich PID 1; endet an einem nicht lesbaren Glied.
    mutating func ancestors(of pid: pid_t, limit: Int) -> [String] {
        var result: [String] = []
        var current = info(pid)?.parent ?? 0
        while current > 1, result.count < limit, let parent = info(current) {
            result.append(parent.process.executablePath)
            current = parent.parent
        }
        return result
    }

    private func read(_ pid: pid_t) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, let process = inspector.process(pid) else {
            return nil
        }
        return Info(process: process, parent: pid_t(bitPattern: bsd.pbi_ppid))
    }
}

private extension [CChar] {
    /// Text bis zum ersten Nullzeichen, als UTF-8 gelesen.
    var nullTerminatedString: String {
        String(decoding: prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
