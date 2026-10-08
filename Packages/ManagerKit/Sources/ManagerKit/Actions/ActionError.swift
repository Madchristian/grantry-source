import Foundation

/// Fehler einer vom Nutzer ausgelösten Aktion.
public enum ActionError: LocalizedError, Equatable {
    /// Die `ActionPolicy` verbietet die Aktion für diesen Eintrag.
    case notAllowed(ActionAvailability.Reason)
    /// Der externe Befehl ist fehlgeschlagen.
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed(let reason): reason.description
        case .commandFailed(let message): message
        }
    }
}

extension ActionError {
    /// Führt einen Helper-Aufruf aus und übersetzt `HelperClientError` in `.commandFailed`; alle anderen Fehler
    /// (insbesondere `CancellationError`) bleiben unverändert.
    static func translatingHelperErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as HelperClientError {
            throw ActionError.commandFailed(error.readableDescription)
        }
    }
}
