import Foundation
import GrantryShared
import Security

/// Admin-Bestätigung je Aktion (Plan TM9, Helper-Entwurf): Der Helper verlangt mit der Ref der App ein Admin-Recht samt
/// Dialog. Blockiert, bis der Mensch antwortet – nur auf einer eigenen Queue aufrufen (`AdminAuthorization.confirm`).
public protocol ActionAuthorizing: Sendable {
    /// - Parameters:
    ///   - externalForm: `AuthorizationExternalForm` der App (Länge vorher geprüft).
    ///   - prompt: Text des Dialogs, aus der eigenen Lesung des Helpers gebaut.
    func authorize(_ externalForm: Data, prompt: String) throws(TaskActionViolation)
}

/// Authorization Services: `system.privilege.admin` (`group admin`, `shared false`) mit `.interactionAllowed` und
/// `.extendRights`; danach immer `AuthorizationFree(…, .destroyRights)`, damit dieselbe Ref keine zweite Aktion trägt.
/// `allow-root` der Regel wertet authd für den Ersteller der Ref aus (die App), nicht für den Helper.
public struct AdminRightAuthorizer: ActionAuthorizing {
    static let right = kAuthorizationRightExecute

    public init() {}

    public func authorize(_ externalForm: Data, prompt: String) throws(TaskActionViolation) {
        let reference = try Self.reference(from: externalForm)
        defer { AuthorizationFree(reference, [.destroyRights]) }
        let status = Self.copyRight(reference, prompt: prompt)
        switch status {
        case errAuthorizationSuccess: return
        case errAuthorizationCanceled: throw .authorizationCanceled
        default: throw .authorizationDenied(status)
        }
    }

    /// Ref aus der externen Form; eine ungültige ergibt `authorizationDenied` ohne Dialog.
    static func reference(from externalForm: Data) throws(TaskActionViolation) -> AuthorizationRef {
        try TaskActionViolation.validateAuthorization(externalForm)
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form.bytes) { _ = externalForm.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        let status = AuthorizationCreateFromExternalForm(&form, &reference)
        guard status == errAuthorizationSuccess, let reference else { throw .authorizationDenied(status) }
        return reference
    }

    private static func copyRight(_ reference: AuthorizationRef, prompt: String) -> OSStatus {
        right.withCString { rightName in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                prompt.withCString { promptText in
                    var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(
                        name: promptKey, valueLength: strlen(promptText),
                        value: UnsafeMutableRawPointer(mutating: promptText), flags: 0
                    )
                    return withUnsafeMutablePointer(to: &item) { items in
                        withUnsafeMutablePointer(to: &promptItem) { environmentItems in
                            var rights = AuthorizationRights(count: 1, items: items)
                            var environment = AuthorizationEnvironment(count: 1, items: environmentItems)
                            return AuthorizationCopyRights(reference, &rights, &environment,
                                                           [.interactionAllowed, .extendRights], nil)
                        }
                    }
                }
            }
        }
    }
}

enum AdminAuthorization {
    /// Eigene Queue für den blockierenden Dialog (Gotcha „blockierende Systemaufrufe“): Der kooperative Pool bleibt frei.
    private static let queue = DispatchQueue(label: "de.cstrube.Grantry.Helper.authorization")

    /// Wartet auf `authorizer`, ohne einen Thread des kooperativen Pools zu belegen.
    static func confirm(_ externalForm: Data, prompt: String, with authorizer: any ActionAuthorizing) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try authorizer.authorize(externalForm, prompt: prompt)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Höchstlänge des Programmnamens im Dialog.
    static let maximumNameLength = 60

    /// Dialogtext aus der Lesung des Helpers: Programmname (einzeilig, gekürzt), PID und Benutzer.
    static func prompt(_ action: String, process: RunningProcess, userName: String) -> String {
        let name = ProcessTerminationPolicy.displayName(of: process.executablePath)
        let shortened = name.count > maximumNameLength ? name.prefix(maximumNameLength - 1) + "…" : name
        let user = DisplayText.singleLine(userName)
        return "Grantry möchte „\(shortened)“ (PID \(process.pid), Benutzer \(user)) \(action)."
    }
}
