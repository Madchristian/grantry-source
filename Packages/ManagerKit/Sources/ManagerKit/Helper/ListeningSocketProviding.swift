/// Liefert lauschende Sockets aller Benutzer; in der App der `HelperClient` (root).
public protocol ListeningSocketProviding: Sendable {
    func listeningSockets() async throws -> ListeningSocketScan
}

extension HelperClient: ListeningSocketProviding {}
