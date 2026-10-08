import Foundation
import ManagerKit

/// Startoptionen, die das Verhalten des Prozesses bestimmen, bevor die App-Modelle entstehen.
enum LaunchOptions {
    /// Nur DEBUG: `-AllowSecondInstance YES` startet eine zweite Instanz neben der laufenden (für
    /// Bildschirmprüfungen); sie nutzt dann eine eigene Ablage (`storage`).
    static var allowsSecondInstance: Bool {
        #if DEBUG
        DevelopmentLaunchOptions.allowsSecondInstance
        #else
        false
        #endif
    }

    /// Ablage von Verlauf, Wiederherstellungsbelegen, Benutzer-Backups und Instanzsperre. Eine zweite Instanz schreibt
    /// nie in diese Dateien der ersten; geteilt bleiben die System-Backups des Helpers und die `UserDefaults`.
    static var storage: StorageLocation {
        allowsSecondInstance ? .standard.subdirectory("Debug-Zweitinstanz") : .standard
    }
}
