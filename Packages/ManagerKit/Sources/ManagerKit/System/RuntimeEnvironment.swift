import Foundation

/// Umgebung, in der der Prozess läuft – ermittelt aus seinen Umgebungsvariablen (für Tests injizierbar).
///
/// Für SwiftUI-Vorschauen startet Xcode die echte App mit `XCODE_RUNNING_FOR_PREVIEWS=1`. Dieser Prozess trägt die
/// Bundle-ID der installierten Grantry, liegt aber in DerivedData und ist anders signiert: Registrierte er Helper oder
/// Login-Item, fragte er `SMAppService` ab oder öffnete er die Ablage, könnte er wie ein gestarteter Debug-Build den
/// BTM-Eintrag der installierten App auf sich umbiegen – sie verlöre Helper und Festplattenvollzugriff.
public struct RuntimeEnvironment: Sendable {
    /// Wie der Prozess startet.
    public enum LaunchMode: Sendable, Equatable {
        /// Die App mit allen Startaufgaben: Datenübernahme, Instanzsperre, Helper, Überwachung, Updates.
        case application
        /// Nur Gastgeber für Xcode-Vorschauen: keine Startaufgabe mit Wirkung auf das System.
        case previewHost
    }

    /// Variable, die Xcode beim Start für SwiftUI-Vorschauen setzt (Wert `1`).
    public static let previewVariable = "XCODE_RUNNING_FOR_PREVIEWS"

    /// Umgebung des laufenden Prozesses.
    public static var current: RuntimeEnvironment {
        RuntimeEnvironment(variables: ProcessInfo.processInfo.environment)
    }

    private let variables: [String: String]

    public init(variables: [String: String]) {
        self.variables = variables
    }

    /// `true`, wenn Xcode den Prozess für SwiftUI-Vorschauen gestartet hat.
    public var isRunningForPreviews: Bool {
        variables[Self.previewVariable] == "1"
    }

    /// Startweg des Prozesses (`AppLauncher`).
    public var launchMode: LaunchMode {
        isRunningForPreviews ? .previewHost : .application
    }
}
