import Foundation

extension ActionConfirmation {
    /// Hinweis aus Spec §6.2: Grantry blockiert nicht dauerhaft.
    static let restartNote = "Der Dienst kann über seinen Autostart-Eintrag bzw. die App erneut starten. "
        + "Grantry blockiert ihn nicht dauerhaft."

    /// „Prozess beenden …“ (SIGTERM): Programm, Port, Erreichbarkeit und PIDs mit Benutzer.
    public static func terminate(_ request: ProcessTerminationRequest, currentUID: UInt32 = getuid()) -> ActionConfirmation {
        let listener = request.listener
        return ActionConfirmation(
            title: "„\(NetworkListenerRow(listener).title)“ beenden?",
            message: [
                "Programm: \(PathDisplay.abbreviatingHome(listener.executablePath))",
                "\(listener.portLabel), \(listener.reachabilityText)",
                "Prozesse: \(processList(request, currentUID: currentUID))",
            ].joined(separator: "\n"),
            note: restartNote,
            confirmTitle: "Beenden",
            isDestructive: true
        )
    }

    /// Zweite Bestätigung für die Überlebenden eines SIGTERM (SIGKILL).
    public static func forceTerminate(_ request: ProcessTerminationRequest, currentUID: UInt32 = getuid()) -> ActionConfirmation {
        ActionConfirmation(
            title: "„\(NetworkListenerRow(request.listener).title)“ sofort beenden (SIGKILL)?",
            message: "Diese Prozesse haben auf die Aufforderung zum Beenden nicht reagiert: "
                + "\(processList(request, currentUID: currentUID)).",
            note: "Die Prozesse enden ohne Aufräumen und können ungesicherte Daten verlieren. " + restartNote,
            confirmTitle: "Sofort beenden",
            isDestructive: true
        )
    }

    /// „PID 4242 (Eigener Benutzer), …“, höchstens `maximumListedNames` Einträge.
    private static func processList(_ request: ProcessTerminationRequest, currentUID: UInt32) -> String {
        list(request.processes.map { "PID \($0.pid) (\(ListenerUser(uid: $0.uid, currentUID: currentUID).displayName))" })
    }
}
