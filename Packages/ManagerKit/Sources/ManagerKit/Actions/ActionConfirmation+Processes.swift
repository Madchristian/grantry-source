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

extension ActionConfirmation {
    /// „Task beenden“ im Task-Manager (SIGTERM, Spec 2026-11-06 §2).
    /// Bei Prozessen anderer Benutzer nennt der Text den Benutzer und kündigt die Admin-Bestätigung an (TM9).
    public static func terminateTask(_ request: TaskTerminationRequest, currentUID: UInt32 = getuid()) -> ActionConfirmation {
        ActionConfirmation(
            title: "„\(request.name)“ beenden?",
            message: "Prozesse: \(taskProcessList(request, currentUID: currentUID)).",
            note: "Ungesicherte Änderungen können verloren gehen. Apps lassen sich in der App selbst mit ⌘Q geordnet "
                + "beenden." + adminNote(request, currentUID: currentUID),
            confirmTitle: "Beenden",
            isDestructive: true
        )
    }

    /// „Sofort beenden“ (SIGKILL), direkt mit ⌥⌫ oder für die Überlebenden eines SIGTERM.
    public static func forceTerminateTask(_ request: TaskTerminationRequest,
                                          currentUID: UInt32 = getuid()) -> ActionConfirmation {
        ActionConfirmation(
            title: "„\(request.name)“ sofort beenden (SIGKILL)?",
            message: "Prozesse: \(taskProcessList(request, currentUID: currentUID)).",
            note: "Die Prozesse enden ohne Aufräumen und können ungesicherte Daten verlieren."
                + adminNote(request, currentUID: currentUID),
            confirmTitle: "Sofort beenden",
            isDestructive: true
        )
    }

    /// Prioritätsänderung (TM-9.3); über den Helper mit Hinweis auf die Admin-Bestätigung.
    public static func setPriority(_ request: TaskPriorityRequest, currentUID: UInt32 = getuid()) -> ActionConfirmation {
        let current = request.currentNice.map { ProcessPriority(nearest: $0).title } ?? "unbekannt"
        let user = request.process.uid == currentUID ? "" : ", Benutzer \(UserAccount.shortName(of: request.process.uid))"
        return ActionConfirmation(
            title: "Priorität von „\(request.name)“ auf „\(request.priority.title)“ setzen?",
            message: "Prozess: PID \(request.process.pid)\(user). Bisher: \(current).",
            note: request.needsHelper(currentUID: currentUID) ? adminPrompt : nil,
            confirmTitle: "Priorität setzen",
            isDestructive: false
        )
    }

    static let adminPrompt = "Danach fragt macOS nach dem Kennwort eines Administrators (oder Touch ID) – je Aktion."

    private static func adminNote(_ request: TaskTerminationRequest, currentUID: UInt32) -> String {
        request.processes.contains { $0.uid != currentUID } ? " " + adminPrompt : ""
    }

    /// „PID 4242“, bei anderen Benutzern „PID 4242 (Benutzer root)“.
    private static func taskProcessList(_ request: TaskTerminationRequest, currentUID: UInt32) -> String {
        list(request.processes.map { process in
            process.uid == currentUID ? "PID \(process.pid)"
                : "PID \(process.pid) (Benutzer \(UserAccount.shortName(of: process.uid)))"
        })
    }
}
