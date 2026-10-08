import GrantryShared

/// Socket-Enumerator mit festem Ergebnis.
public struct FixedSockets: ListeningSocketEnumerating {
    public let result: Result<ListeningSocketScan, ListeningSocketError>

    public init(result: Result<ListeningSocketScan, ListeningSocketError>) {
        self.result = result
    }

    public func listeningSockets() throws -> ListeningSocketScan { try result.get() }
}
