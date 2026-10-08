import Foundation

extension Error {
    /// Lesbare Fehlermeldung: `LocalizedError.errorDescription`, sonst die Beschreibung des Fehlers.
    public var readableDescription: String {
        (self as? any LocalizedError)?.errorDescription ?? String(describing: self)
    }
}
