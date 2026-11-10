import Observation

/// Anmeldungen für den Tab „Benutzer“: liest utmpx abseits des Main Actors (`BlockingWorkQueue`), sobald die Oberfläche
/// `refresh()` aufruft – beim Erscheinen und danach im Takt, solange der Tab sichtbar ist.
@MainActor
@Observable
public final class LoginSessionsModel {
    public private(set) var sessions: [LoginSession] = []

    @ObservationIgnored private let read: @Sendable () -> [LoginSession]
    @ObservationIgnored private let queue = BlockingWorkQueue(label: "login-sessions")

    public init(read: @escaping @Sendable () -> [LoginSession] = { LoginSessions.current() }) {
        self.read = read
    }

    public func refresh() async {
        sessions = await queue.run(read)
    }
}
