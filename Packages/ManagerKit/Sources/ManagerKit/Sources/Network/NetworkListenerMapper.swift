import Foundation

/// Bildet Rohsockets auf `NetworkListener` ab (Spec §5): gruppiert nach Programm, Benutzer, Transport und Port, vom
/// System vergebene Ports als „wechselnd“ (`ListenerPort.isVariable`) – auch bei UDP: Dort lauschen neben Clients
/// (STUN, WebRTC) auch Dienste wie WireGuard (51820, ausdrücklich gewählt, bleibt fest) oder eine Hintertür auf
/// `0.0.0.0`; die Ausnahme für Clients trifft erst die Bewertung (`NetworkListener.isBenignClientUDP`). Leere Adressen
/// (`inet_ntop` gescheitert) fallen aus der Adressliste, der Lauscher bleibt. Die Signatur wird je Programm einmal
/// geprüft; die Elternkette stammt vom Prozess mit der kleinsten PID.
public struct NetworkListenerMapper: Sendable {
    private let inspector: any SigningInspecting

    public init(inspector: any SigningInspecting = CachingSigningInspector()) {
        self.inspector = inspector
    }

    public func listeners(from sockets: [ListeningSocket], at date: Date) -> [NetworkListener] {
        let groups = Dictionary(grouping: sockets, by: GroupKey.init)
        var signatures: [String: SigningInfo] = [:]
        var listeners: [NetworkListener] = []
        for (key, members) in groups {
            let signing = signatures[key.path] ?? inspector.inspect(path: key.path)
            signatures[key.path] = signing
            let first = members.min { $0.pid < $1.pid }
            listeners.append(NetworkListener(
                executablePath: key.path, uid: key.uid, transport: key.transport, port: key.port,
                addresses: members.map(\.localAddress).filter { !$0.isEmpty }, signing: signing,
                ancestorPaths: first?.ancestors ?? [], firstSeenAt: date, lastSeenAt: date
            ))
        }
        return listeners.sorted { $0.id < $1.id }
    }

    struct GroupKey: Hashable {
        let path: String
        let uid: UInt32
        let transport: SocketTransport
        let port: UInt16?

        init(_ socket: ListeningSocket) {
            path = socket.executablePath
            uid = socket.uid
            transport = socket.transport
            port = ListenerPort.isVariable(socket) ? nil : socket.localPort
        }

        /// Schlüssel eines bereits gebildeten Lauschers – derselbe, unter dem der Mapper seine Sockets gruppiert hat
        /// (`ListenerProcessResolver`).
        init(_ listener: NetworkListener) {
            path = listener.executablePath
            uid = listener.uid
            transport = listener.transport
            port = listener.port
        }
    }
}
