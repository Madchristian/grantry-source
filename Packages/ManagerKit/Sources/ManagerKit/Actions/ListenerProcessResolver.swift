import Foundation

/// Ermittelt die Prozesse hinter einem Lauscher frisch aus den Sockets (Spec §2): Lauscher speichern keine PIDs, und
/// zwischen Scan und Klick können Prozesse enden oder neu starten. Abgleich über `NetworkListenerMapper.GroupKey` –
/// dieselbe Gruppierung wie in der Anzeige (Pfad, uid, Transport, Port bzw. Ephemeral → „wechselnd“).
///
/// Eigene Lauscher liest der lokale `LibprocSocketEnumerator`, fremde nur der Helper (`provider`). Die Prozesse selbst
/// liest `inspector` (auch fremde als Benutzer lesbar) – mit der Startzeit, mit der die Prüfung vor dem Signal eine
/// neu vergebene PID erkennt (`RunningProcess`). Ein Prozess zählt nur, wenn er noch derselbe ist wie beim Lesen des
/// Sockets (`ListeningSocket.belongs(to:)`: PID, Benutzer, Programm **und** Startzeit); sonst – beendet, anderer Pfad
/// oder Benutzer, oder ein neuer Prozess desselben Programms unter derselben PID (#153, Befund 2) – fällt er weg. Ist
/// nur seine Identität gerade nicht bestätigt, scheitert die Auflösung (`identityUnknown`), statt ihn wegfallen zu lassen.
public struct ListenerProcessResolver: Sendable {
    private let provider: (any ListeningSocketProviding)?
    private let local: any ListeningSocketEnumerating
    private let inspector: any ProcessInspecting
    private let currentUID: UInt32
    private let queue = BlockingWorkQueue(label: "listener-process-sockets")

    public init(
        provider: (any ListeningSocketProviding)?,
        local: any ListeningSocketEnumerating = LibprocSocketEnumerator(),
        inspector: any ProcessInspecting = LibprocProcessInspector(),
        currentUID: UInt32 = getuid()
    ) {
        self.provider = provider
        self.local = local
        self.inspector = inspector
        self.currentUID = currentUID
    }

    /// - Returns: die Prozesse des Lauschers; leer, wenn er nicht mehr läuft.
    /// - Throws: `ProcessTerminationError.helperRequired` für einen fremden Lauscher ohne Helper,
    ///   `ProcessTerminationViolation.identityUnknown` für einen laufenden Prozess ohne bestätigte Identität,
    ///   `ActionError.commandFailed` bei einem Helper-Fehler, Fehler des lokalen Enumerators unverändert.
    public func request(for listener: NetworkListener) async throws -> ProcessTerminationRequest {
        let key = NetworkListenerMapper.GroupKey(listener)
        let byPID = Dictionary(
            try await sockets(for: listener)
                .filter { NetworkListenerMapper.GroupKey($0) == key }
                .map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let processes = try byPID.values.compactMap(process(owning:))
        return ProcessTerminationRequest(listener: listener, processes: processes.sorted { $0.pid < $1.pid })
    }

    /// Der Prozess hinter `socket`, sofern er noch derselbe ist (auch dieselbe Startzeit); `nil`, wenn er nachweislich
    /// nicht mehr derselbe ist.
    ///
    /// - Throws: `ProcessTerminationViolation.identityUnknown`, wenn die Identität nicht bestätigt werden kann, unter
    ///   PID und Startzeit des Sockets aber noch etwas läuft (oder der Zustand nicht feststellbar ist): Fiele er still
    ///   weg, könnte das Beenden der übrigen Prozesse den Lauscher als beendet vermerken (#153, Codex-Runde 3).
    private func process(owning socket: ListeningSocket) throws(ProcessTerminationViolation) -> RunningProcess? {
        if let process = inspector.process(socket.pid) { return socket.belongs(to: process) ? process : nil }
        guard let startTime = socket.startTime, !inspector.hasEnded(socket.pid, startedAt: startTime) else { return nil }
        throw .identityUnknown(socket.pid)
    }

    private func sockets(for listener: NetworkListener) async throws -> [ListeningSocket] {
        if listener.uid == currentUID {
            return try await queue.runThrowing { try local.listeningSockets().sockets }
        }
        guard let provider else { throw ProcessTerminationError.helperRequired }
        return try await ActionError.translatingHelperErrors { try await provider.listeningSockets() }.sockets
    }
}
